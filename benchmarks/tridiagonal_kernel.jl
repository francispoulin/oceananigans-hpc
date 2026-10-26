# The batched tridiagonal solve alone, on one GPU: Oceananigans.Solvers.BatchedTridiagonalSolver in z,
# the kernel used by the Fourier-tridiagonal pressure solver (on complex numbers) and by vertically
# implicit diffusion (on real numbers, e.g. CATKE). A small, quick check of that one kernel when
# Julia or Oceananigans changes (Oct 25: 3.8 times slower with Julia 1.13.2 + Oceananigans 0.116.1,
# found by tools/compare_speed.sh --profile). After ocean_setup, in any worktree:
#
#     CUDA_VISIBLE_DEVICES=0 julia --project=. benchmarks/tridiagonal_kernel.jl
#     CUDA_VISIBLE_DEVICES=0 julia --project=. benchmarks/tridiagonal_kernel.jl --size=512x512x1024 --float=Float32
#     CUDA_VISIBLE_DEVICES=0 julia --project=. benchmarks/tridiagonal_kernel.jl --size=1024x256x1024 --y-topology=connected
#
# Options (all --name=value):
#   --size=512x512x1024   grid; the default has the cells of one GPU's share of the 1024³ benchmark on 4 GPUs
#                         (in that run each GPU solves on 1024x256x1024: x whole, y split in 4)
#   --float=Float32       Float32 | Float64
#   --reps=20             solves per timing window (5 windows; the fastest is reported)
#   --y-topology=periodic periodic | connected. "connected" gives the grid the y topology of one rank of a
#                         distributed grid split in y (FullyConnected up to Oceananigans 0.115,
#                         Sides{Connected, Connected} from 0.116), so the kernel is compiled for the same
#                         grid type as in a multi-GPU run, on one GPU and without MPI. (Oct 26: the profiles
#                         of the 4-GPU run showed the same kernel and arrays in both versions; only the
#                         grid's topology types differed.)
# Prints one line per element type: RESULT tridiagonal phi=complex|real size=... t_min_ms=...
# t_median_ms=... checksum=... (the same on every Julia and Oceananigans version, to round-off) and
# the versions of Julia, Oceananigans, KernelAbstractions and CUDA.

using Oceananigans, CUDA, Printf, Statistics
using Oceananigans.Solvers: BatchedTridiagonalSolver, solve!
using Random

opts = Dict("size" => "512x512x1024", "float" => "Float32", "reps" => "20", "y-topology" => "periodic")
for a in ARGS
    m = match(r"^--([a-z-]+)=(.*)$", a)
    m === nothing && error("bad argument '$a' (use --name=value)")
    haskey(opts, m[1]) || error("unknown option --$(m[1]); known: $(join(sort(collect(keys(opts))), ", "))")
    opts[m[1]] = m[2]
end
Nx, Ny, Nz = parse.(Int, split(opts["size"], 'x'))
FT   = opts["float"] == "Float32" ? Float32 : opts["float"] == "Float64" ? Float64 : error("--float must be Float32 or Float64")
reps = parse(Int, opts["reps"])

connected = isdefined(Oceananigans.Grids, :Sides) ?
            Oceananigans.Grids.Sides{Oceananigans.Grids.Connected, Oceananigans.Grids.Connected} :
            Oceananigans.Grids.FullyConnected
TY = opts["y-topology"] == "periodic"  ? Periodic :
     opts["y-topology"] == "connected" ? connected :
     error("--y-topology must be periodic or connected")

grid  = RectilinearGrid(GPU(), FT; size=(Nx, Ny, Nz), x=(0, 1), y=(0, 1), z=(-1, 0), topology=(Periodic, TY, Bounded))
lower = CuArray(fill(FT(1), Nz - 1))                      # as the pressure solver: 1-D off-diagonals,
diag  = CuArray(fill(FT(-4), Nx, Ny, Nz))                 # a 3-D main diagonal (diagonally dominant)
solver = BatchedTridiagonalSolver(grid; lower_diagonal=lower, diagonal=diag, upper_diagonal=lower)

versions = join(("julia=$(VERSION)",
                 "Oceananigans=$(pkgversion(Oceananigans))",
                 "KernelAbstractions=$(pkgversion(Oceananigans.Architectures.KA))",
                 "CUDA=$(pkgversion(CUDA))"), " ")
for (label, T) in (("complex", Complex{FT}), ("real", FT))
    rhs = CuArray(rand(Xoshiro(1), T, Nx, Ny, Nz))
    ϕ   = similar(rhs)
    solve!(ϕ, solver, rhs); CUDA.synchronize()               # compile
    times = [CUDA.@elapsed(for _ in 1:reps; solve!(ϕ, solver, rhs); end) / reps for _ in 1:5]
    checksum = sum(x -> Float64(abs(x)), Array(ϕ)) / length(ϕ)
    @printf("RESULT tridiagonal phi=%s size=%dx%dx%d float=%s y_topology=%s t_min_ms=%.3f t_median_ms=%.3f checksum=%.12e %s gpu=\"%s\"\n",
            label, Nx, Ny, Nz, FT, opts["y-topology"], 1e3 * minimum(times), 1e3 * median(times), checksum, versions, CUDA.name(CUDA.device()))
    flush(stdout)
end

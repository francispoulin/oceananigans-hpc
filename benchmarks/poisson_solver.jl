# Pressure solver alone: time the nonhydrostatic pressure solve (source term + distributed Poisson
# solve) without the rest of the model, on 1 or more GPUs (one MPI rank per GPU, grid split in x),
# with MPI or NCCL for the transposes. Same grid as benchmarks/nonhydrostatic_box.jl.
#
# The solver is built exactly as NonhydrostaticModel builds it (nonhydrostatic_pressure_solver), and
# solve_for_pressure! is the call the model makes 3 times per RK3 step. Only the velocities and the
# pressure exist (no tendencies, tracers or closures), so the run is light and quick to profile.
#
# Usage (from the repository root, after ocean_setup):
#   bash tools/run_local.sh --wait --gpus 2 --job-name poisson_FT_MPI_2gpu benchmarks/poisson_solver.jl --solver=FourierTridiagonal
#   NCCL needs NCCL.jl in the environment: bash setup/setup_nccl_env.sh once, then add -p envs/nccl
#   and --comm=NCCL (see benchmarks/README.md).
#
# Options (all --name=value):
#   --size=512x512x256   GLOBAL grid size (Nx and Ny divisible by the number of GPUs)
#   --solver=FourierTridiagonal   FourierTridiagonal (z stretched) | FFT (uniform)
#   --comm=MPI           MPI | NCCL (Oceananigans' NCCLDistributed; transposes and halos over NCCL)
#   --float=Float64      Float64 | Float32
#   --reps=20            solves per timing window
#   --windows=5          timing windows
#   --warmup=3           untimed solves first (compilation)
#   --profile=false      true: 3 more solves inside CUDA.@profile external=true, for
#                        nsys profile --capture-range=cudaProfilerApi
#
# Prints one line starting with "RESULT poisson". Correctness check: p_std (root-mean-square of the
# pressure about its mean, over the whole grid) should agree between 1 and N GPUs and between MPI
# and NCCL to roundoff. p_mean may differ: pressure is defined up to a constant, and the serial and
# distributed solvers may fix that constant differently (harmless: only gradients are used).

using Oceananigans
using Oceananigans.Models.NonhydrostaticModels: nonhydrostatic_pressure_solver, solve_for_pressure!
using Oceananigans.BoundaryConditions: fill_halo_regions!
using Oceananigans.DistributedComputations: TransposableField, transpose_y_to_x!, transpose_x_to_y!
using CUDA
using Printf, Statistics

# ---------------------------------------------------------------- options
function parse_options(args)
    opts = Dict("size" => "512x512x256", "solver" => "FourierTridiagonal", "comm" => "MPI",
                "float" => "Float64", "reps" => "20", "windows" => "5", "warmup" => "3",
                "profile" => "false")
    for a in args
        m = match(r"^--([a-z_]+)=(.*)$", a)
        m === nothing && error("bad argument '$a' (use --name=value)")
        haskey(opts, m[1]) || error("unknown option --$(m[1]); known: $(join(sort(collect(keys(opts))), ", "))")
        opts[m[1]] = m[2]
    end
    return opts
end

opts     = parse_options(ARGS)
solver_name = opts["solver"]
solver_name in ("FFT", "FourierTridiagonal") || error("--solver must be FFT or FourierTridiagonal")
comm_name = uppercase(opts["comm"])
comm_name in ("MPI", "NCCL") || error("--comm must be MPI or NCCL")
FT       = opts["float"] == "Float32" ? Float32 : opts["float"] == "Float64" ? Float64 : error("--float must be Float64 or Float32")
nreps    = parse(Int, opts["reps"])
nwindows = parse(Int, opts["windows"])
nwarmup  = parse(Int, opts["warmup"])
profile  = lowercase(opts["profile"]) in ("true", "1", "yes")
Nx, Ny, Nz = parse.(Int, split(opts["size"], 'x'))

# NCCL.jl loads Oceananigans' NCCL extension (NCCLDistributed). Only in an environment that has it.
if comm_name == "NCCL"
    @eval using NCCL
end

include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()
comm   = MPI.COMM_WORLD
rank   = MPI.Comm_rank(comm)
nranks = MPI.Comm_size(comm)
say(x...) = rank == 0 && (println(x...); flush(stdout))

Nx % nranks == 0 || error("Nx = $Nx is not divisible by $nranks GPUs")
Ny % nranks == 0 || error("Ny = $Ny must be divisible by $nranks GPUs (distributed Poisson solver)")

partition = Partition(nranks, 1, 1)
arch = if nranks == 1
    GPU()
elseif comm_name == "NCCL"
    Oceananigans.DistributedComputations.NCCLDistributed(GPU(); partition)
else
    Distributed(GPU(); partition)
end
comm_name == "NCCL" && nranks == 1 && say("note: 1 GPU, no communication: --comm has no effect")

# ---------------------------------------------------------------- grid, velocities, solver
Oceananigans.defaults.FloatType = FT
Lx = Ly = FT(1000)
Lz = FT(500)
z  = solver_name == "FourierTridiagonal" ? ExponentialDiscretization(Nz, -Lz, 0; scale = Lz / 2) : (-Lz, 0)
grid = RectilinearGrid(arch; size = (Nx, Ny, Nz), halo = (4, 4, 4),
                       x = (0, Lx), y = (0, Ly), z, topology = (Periodic, Periodic, Bounded))

u = XFaceField(grid); v = YFaceField(grid); w = ZFaceField(grid)
set!(u, (x, y, z) -> 0.05 + 0.005 * sin(6π * x / Lx) * cos(4π * y / Ly) * cos(π * z / Lz))
set!(v, (x, y, z) ->        0.005 * cos(4π * x / Lx) * sin(6π * y / Ly) * cos(π * z / Lz))
set!(w, (x, y, z) ->        0.001 * sin(2π * x / Lx) * sin(2π * y / Ly) * sin(π * z / Lz))
fill_halo_regions!((u, v, w))
velocities = (; u, v, w)
pressure   = CenterField(grid)

solver = nonhydrostatic_pressure_solver(grid, nothing)       # as NonhydrostaticModel does
Δt = one(FT)
solve() = solve_for_pressure!(pressure, solver, nothing, velocities, Δt)

say("Pressure solver alone: ", Nx, "x", Ny, "x", Nz, " (", round(Nx * Ny * Nz / 1e6, digits = 1), "M cells), ",
    nranks, " GPU(s), ", comm_name, ", ", nameof(typeof(solver)), ", ", FT)

# ---------------------------------------------------------------- timing
sync() = (CUDA.synchronize(); MPI.Barrier(comm))

function time_per_call(f, n)
    sync()
    t0 = time_ns()
    for _ in 1:n
        f()
    end
    sync()
    return (time_ns() - t0) / 1e9 / n
end

for _ in 1:nwarmup
    solve()
end
sync()

times = [time_per_call(solve, nreps) for _ in 1:nwindows]
for (i, t) in enumerate(times)
    say(@sprintf("  window %d: %.3f ms per solve", i, 1e3 * t))
end

t_trans = NaN      # y -> x and x -> y: the two transposes of one solve with an x-split
if nranks > 1 && hasproperty(solver, :storage) && solver.storage isa TransposableField
    st = solver.storage
    t_trans = minimum(time_per_call(() -> (transpose_y_to_x!(st); transpose_x_to_y!(st)), nreps) for _ in 1:3)
end

if profile
    sync()
    CUDA.@profile external=true begin
        for _ in 1:3
            solve()
        end
        CUDA.synchronize()
    end
    sync()
    say("profiled 3 solves (Nsight Systems capture range)")
end

# ---------------------------------------------------------------- correctness and memory
solve(); sync()
p_local  = Array(interior(pressure))
local_ok = all(isfinite, p_local)
all_ok   = MPI.Allreduce(local_ok ? 1 : 0, MPI.MIN, comm) == 1
ncells   = Nx * Ny * Nz
p_mean   = MPI.Allreduce(sum(Float64, p_local), +, comm) / ncells
p_rms    = sqrt(MPI.Allreduce(sum(abs2, Float64.(p_local)), +, comm) / ncells)
p_std    = sqrt(MPI.Allreduce(sum(x -> (x - p_mean)^2, Float64.(p_local)), +, comm) / ncells)

# GPU memory of THIS process (nvidia-smi), and whether another process shares our GPU
function gpu_usage()
    mine, others = NaN, false
    uuid = string(CUDA.uuid(CUDA.device()))
    try
        out = read(`nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader,nounits`, String)
        for line in split(out, '\n')
            f = strip.(split(line, ','))
            length(f) == 3 || continue
            occursin(lowercase(uuid), lowercase(f[2])) || continue
            if parse(Int, f[1]) == getpid()
                mine = parse(Float64, f[3]) * 2^20
            else
                others = true
            end
        end
    catch
    end
    isnan(mine) && (mine = Float64(CUDA.total_memory() - CUDA.free_memory()))
    return mine, others
end
memory, shared = gpu_usage()
memory = MPI.Allreduce(memory, MPI.MAX, comm)
shared = MPI.Allreduce(shared ? 1 : 0, MPI.MAX, comm) == 1
shared && say("WARNING: another process was using one of our GPUs: timings and memory are not reliable")

say(@sprintf("RESULT poisson solver=%s size=%dx%dx%d gpus=%d comm=%s float=%s t_solve_min_ms=%.3f t_solve_median_ms=%.3f t_transposes_ms=%.3f p_std=%.12e p_mean=%.6e p_rms=%.10e mem_GiB=%.2f finite=%s shared_gpu=%s gpu=\"%s\"",
             solver_name, Nx, Ny, Nz, nranks, comm_name, FT, 1e3 * minimum(times), 1e3 * median(times),
             1e3 * t_trans, p_std, p_mean, p_rms, memory / 2^30, all_ok, shared, CUDA.name(CUDA.device())))

all_ok || error("non-finite pressure")

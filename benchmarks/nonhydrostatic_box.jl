# Nonhydrostatic benchmark: time per step of a NonhydrostaticModel in a stratified, rotating box,
# on 1 or more GPUs (one MPI rank per GPU, grid split in x). Same configuration as the
# `nonhydrostatic` case of the newer Oceananigans benchmark suite (benchmarking/src/
# nonhydrostatic_box.jl on Oceananigans main), written for the Oceananigans version in this
# repository at v1.0.0 (0.113.5), with multi-GPU support and the same timing method as our hydrostatic runs.
#
#   Box 1 km x 1 km x 500 m, Periodic x Periodic x Bounded, WENO(5), f = 1e-4, buoyancy tracer,
#   N^2 = 1e-5, U = 0.05 m/s mean flow + deterministic sinusoidal perturbation. RK3, fixed dt.
#
# Pressure solvers (--solver):
#   FFT                 uniform grid; 1 GPU: FFTBasedPoissonSolver, several: DistributedFFTBasedPoissonSolver
#   FourierTridiagonal  z stretched (ExponentialDiscretization); several GPUs: the distributed version
#   ConjugateGradient   seamount (immersed boundary), FFT-preconditioned CG. Single GPU only
#                       (not supported on distributed grids in this version, as far as we know).
#
# Usage (from the repository root, after ocean_setup):
#   pelee/rondeau:  bash tools/run_local.sh --wait --gpus 2 --job-name nh_fft_2gpu benchmarks/nonhydrostatic_box.jl --solver=FFT
#   Alliance:       sbatch --ntasks-per-node=2 jobs/benchmark_nh.sh            (see that file)
#
# Options (all --name=value):
#   --size=512x512x256   GLOBAL grid size for strong scaling (Nx must be divisible by the GPUs,
#                        Ny too: distributed Poisson solver). With --weak, the size PER GPU (Nx is
#                        multiplied by the number of GPUs).
#   --weak=false
#   --solver=FFT         FFT | FourierTridiagonal | ConjugateGradient
#   --float=Float64      Float64 | Float32
#   --steps=100          time steps per timing window
#   --windows=5          timing windows
#   --warmup=10          untimed steps first (compilation)
#   --dt=0               0 = automatic: 0.2 * min(dx, dz) / 0.06 m/s
#   --output=            JSON file (default results/raw/nh_<solver>_<size>_<n>gpu_<date>.json;
#                        results/raw/ is not under version control)
#   --device=GPU         GPU | CPU
#   --comm=MPI           MPI | NCCL: NCCLDistributed (transposes and halos over NCCL); needs NCCL.jl
#                        in the environment (setup/setup_nccl_env.sh, then run_local.sh --project envs/nccl)
#   --parts=false        true: after the step timing, also time the pieces of a step (pressure solve
#                        alone, the pair of distributed transposes, one halo fill of u, v, w) and
#                        print a second line "RESULT nhparts ..." (see benchmarks/README.md)
#   --profile=false      true: after the warm-up, run 2 more steps between cudaProfilerStart/Stop,
#                        for Nsight Systems with --capture-range=cudaProfilerApi (only those steps
#                        are recorded, not the compilation). See benchmarks/README.md.
#
# Prints one line starting with "RESULT" (easy to grep) and writes a JSON file (rank 0).

using Oceananigans
using Oceananigans.Solvers: ConjugateGradientPoissonSolver
using MPI
using Printf, Dates, Statistics

# ---------------------------------------------------------------- options
function parse_options(args)
    opts = Dict("size" => "512x512x256", "weak" => "false", "solver" => "FFT", "float" => "Float64",
                "steps" => "100", "windows" => "5", "warmup" => "10", "dt" => "0",
                "output" => "", "device" => "GPU", "parts" => "false", "profile" => "false",
                "comm" => "MPI")
    for a in args
        m = match(r"^--([a-z_]+)=(.*)$", a)
        m === nothing && error("bad argument '$a' (use --name=value)")
        haskey(opts, m[1]) || error("unknown option --$(m[1]); known: $(join(sort(collect(keys(opts))), ", "))")
        opts[m[1]] = m[2]
    end
    return opts
end

opts     = parse_options(ARGS)
solver   = opts["solver"]
solver in ("FFT", "FourierTridiagonal", "ConjugateGradient") || error("--solver must be FFT, FourierTridiagonal or ConjugateGradient")
FT       = opts["float"] == "Float32" ? Float32 : opts["float"] == "Float64" ? Float64 : error("--float must be Float64 or Float32")
weak     = lowercase(opts["weak"]) in ("true", "1", "yes")
parts    = lowercase(opts["parts"]) in ("true", "1", "yes")
profile  = lowercase(opts["profile"]) in ("true", "1", "yes")
nsteps   = parse(Int, opts["steps"])
nwindows = parse(Int, opts["windows"])
nwarmup  = parse(Int, opts["warmup"])
Nx0, Ny, Nz = parse.(Int, split(opts["size"], 'x'))

# ---------------------------------------------------------------- MPI and architecture
use_gpu = opts["device"] == "GPU"
use_gpu && @eval using CUDA
comm_name = uppercase(opts["comm"])
comm_name in ("MPI", "NCCL") || error("--comm must be MPI or NCCL")
comm_name == "NCCL" && !use_gpu && error("--comm=NCCL needs --device=GPU")
comm_name == "NCCL" && @eval using NCCL        # loads Oceananigans' NCCL extension

# Start MPI the safe way on our machines (see src/drac_mpi.jl), also for one rank.
include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()
comm   = MPI.COMM_WORLD
rank   = MPI.Comm_rank(comm)
nranks = MPI.Comm_size(comm)
say(x...) = rank == 0 && (println(x...); flush(stdout))

Nx = weak ? Nx0 * nranks : Nx0
Nx % nranks == 0 || error("Nx = $Nx is not divisible by $nranks GPUs")
Ny % nranks == 0 || error("Ny = $Ny must be divisible by the number of GPUs ($nranks) for the distributed Poisson solver")
solver == "ConjugateGradient" && nranks > 1 && error("--solver=ConjugateGradient: single GPU only in this benchmark")

child = use_gpu ? GPU() : CPU()
arch  = if nranks == 1
    child
elseif comm_name == "NCCL"
    Oceananigans.DistributedComputations.NCCLDistributed(child; partition = Partition(nranks, 1, 1))
else
    Distributed(child; partition = Partition(nranks, 1, 1))
end

# ---------------------------------------------------------------- model (as nonhydrostatic_box)
Oceananigans.defaults.FloatType = FT
Lx = Ly = FT(1000)
Lz = FT(500)
z  = solver == "FourierTridiagonal" ? ExponentialDiscretization(Nz, -Lz, 0; scale = Lz / 2) : (-Lz, 0)

grid = RectilinearGrid(arch; size = (Nx, Ny, Nz), halo = (4, 4, 4),
                       x = (0, Lx), y = (0, Ly), z, topology = (Periodic, Periodic, Bounded))

pressure_solver = nothing        # let the model choose (distributed solver on several GPUs)
if solver == "ConjugateGradient"
    seamount(x, y) = -Lz + 100 * exp(-((x - Lx / 2)^2 + (y - Ly / 2)^2) / 200^2)
    grid = ImmersedBoundaryGrid(grid, GridFittedBottom(seamount))
    pressure_solver = ConjugateGradientPoissonSolver(grid)
end

model = NonhydrostaticModel(grid; pressure_solver,
                            advection = WENO(FT; order = 5),
                            coriolis  = FPlane(FT; f = 1e-4),
                            buoyancy  = BuoyancyTracer(),
                            tracers   = :b)

U, ε, N² = 0.05, 0.005, 1e-5
uᵢ(x, y, z) = U + ε * sin(6π * x / Lx) * cos(4π * y / Ly) * cos(π * z / Lz)
vᵢ(x, y, z) =     ε * cos(4π * x / Lx) * sin(6π * y / Ly) * cos(π * z / Lz)
bᵢ(x, y, z) = N² * z
set!(model, u = uᵢ, v = vᵢ, b = bᵢ)

Δx  = Lx / Nx
zcolumn = RectilinearGrid(CPU(); size = (1, 1, Nz), x = (0, 1), y = (0, 1), z,
                          topology = (Periodic, Periodic, Bounded))    # small CPU copy of z
Δzmin = minimum(diff(collect(znodes(zcolumn, Face()))))
Δt  = parse(Float64, opts["dt"])
Δt  = Δt > 0 ? Δt : 0.2 * min(Δx, Δzmin) / 0.06
Δt  = FT(Δt)

say("Nonhydrostatic box: ", Nx, "x", Ny, "x", Nz, " (", round(Nx * Ny * Nz / 1e6, digits = 1), "M cells), ",
    nranks, " rank(s) on ", use_gpu ? "GPU" : "CPU", ", solver ", solver, ", ", FT, ", dt = ", Δt, " s",
    weak ? " (weak scaling)" : "")
say("pressure solver: ", nameof(typeof(model.pressure_solver)))

# ---------------------------------------------------------------- timing
sync() = (use_gpu && CUDA.synchronize(); MPI.Barrier(comm))

for _ in 1:nwarmup
    time_step!(model, Δt)
end
sync()

# Nsight Systems capture (--profile=true): 2 steps, already compiled, inside
# CUDA.@profile external=true (cudaProfilerStart/Stop). Run under
# `nsys profile --capture-range=cudaProfilerApi`, which records only this part.
if profile && use_gpu
    nprofile = 2
    sync()
    CUDA.@profile external=true begin
        for _ in 1:nprofile
            time_step!(model, Δt)
        end
        CUDA.synchronize()
    end
    sync()
    say("profiled $nprofile steps (Nsight Systems capture range)")
end

times = Float64[]
for w in 1:nwindows
    sync()
    t0 = time_ns()
    for _ in 1:nsteps
        time_step!(model, Δt)
    end
    sync()
    push!(times, (time_ns() - t0) / 1e9 / nsteps)
    say(@sprintf("  window %d: %.4f s/step", w, times[end]))
end

# ---------------------------------------------------------------- pieces of a step (--parts=true)
# An RK3 step does 3 pressure solves (one per substep). Timing the solve alone on 1 and N GPUs
# separates the cost of the distributed Poisson solver from the rest of the model:
#   rest of the step = t_step - 3 t_solve.
# Each piece is repeated `--steps` times on the current state (the solve does not change the
# velocities; the halo fill only rewrites halos), after one untimed call.
if parts
    NHM = Oceananigans.Models.NonhydrostaticModels
    DC  = Oceananigans.DistributedComputations
    psolver  = model.pressure_solver
    pressure = model.pressures.pNHS

    function time_piece(f, n)
        f(); sync()
        t0 = time_ns()
        for _ in 1:n
            f()
        end
        sync()
        return (time_ns() - t0) / 1e9 / n
    end

    t_solve = time_piece(() -> NHM.solve_for_pressure!(pressure, psolver, model.free_surface,
                                                         model.velocities, Δt), nsteps)
    t_halo  = time_piece(() -> Oceananigans.BoundaryConditions.fill_halo_regions!(model.velocities), nsteps)
    t_trans = NaN     # y -> x and x -> y: what one pressure solve does with an x-split
    if nranks > 1 && hasproperty(psolver, :storage) && psolver.storage isa DC.TransposableField
        st = psolver.storage
        t_trans = time_piece(() -> (DC.transpose_y_to_x!(st); DC.transpose_x_to_y!(st)), nsteps)
    end
    t_rest = minimum(times) - 3 * t_solve

    say(@sprintf("  pressure solve %.2f ms (x3 per step = %.1f ms), transposes per solve %s, halo fill u,v,w %.2f ms, rest of step %.1f ms",
                 1e3 * t_solve, 3e3 * t_solve, isnan(t_trans) ? "n/a" : @sprintf("%.2f ms", 1e3 * t_trans),
                 1e3 * t_halo, 1e3 * t_rest))
    say(@sprintf("RESULT nhparts solver=%s size=%dx%dx%d gpus=%d comm=%s weak=%s t_step_ms=%.2f t_solve_ms=%.3f t_transposes_ms=%.3f t_halo_uvw_ms=%.3f t_rest_ms=%.2f",
                 solver, Nx, Ny, Nz, nranks, comm_name, weak, 1e3 * minimum(times), 1e3 * t_solve,
                 1e3 * t_trans, 1e3 * t_halo, 1e3 * t_rest))
end

# Sanity: the flow must still be finite (all ranks).
local_ok = all(isfinite, interior(model.velocities.u)) && all(isfinite, interior(model.tracers.b))
all_ok   = MPI.Allreduce(local_ok ? 1 : 0, MPI.MIN, comm) == 1

# GPU memory of THIS process (from nvidia-smi), and whether another process shares our GPU.
# (The whole-device figure would include other users' jobs: pelee/rondeau have no scheduler.)
function gpu_usage()
    use_gpu || return 0.0, false
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
    isnan(mine) && (mine = Float64(CUDA.total_memory() - CUDA.free_memory()))   # fallback: whole device
    return mine, others
end
memory, shared = gpu_usage()
memory = MPI.Allreduce(memory, MPI.MAX, comm)
shared = MPI.Allreduce(shared ? 1 : 0, MPI.MAX, comm) == 1
shared && say("WARNING: another process was using one of our GPUs: timings and memory are not reliable")

tmin, tmed, tmax = minimum(times), median(times), maximum(times)
ncells = Nx * Ny * Nz
gpu    = use_gpu ? CUDA.name(CUDA.device()) : "CPU"

say(@sprintf("RESULT nh solver=%s size=%dx%dx%d gpus=%d comm=%s weak=%s float=%s t_step_min=%.5f t_step_median=%.5f t_step_max=%.5f cells_per_s=%.3e mem_GiB=%.2f finite=%s shared_gpu=%s gpu=\"%s\"",
             solver, Nx, Ny, Nz, nranks, comm_name, weak, FT, tmin, tmed, tmax, ncells / tmin, memory / 2^30, all_ok, shared, gpu))

if rank == 0
    stamp  = Dates.format(now(), "yyyymmdd-HHMMSS")
    output = isempty(opts["output"]) ? joinpath("results", "raw", "nh_$(solver)_$(Nx)x$(Ny)x$(Nz)_$(nranks)gpu_$(stamp).json") : opts["output"]
    mkpath(dirname(output))
    q(s) = "\"" * replace(string(s), "\"" => "\\\"") * "\""
    fields = [
        "name"                         => q("NonhydrostaticBox_$(solver)_$(Nx)x$(Ny)x$(Nz)_$(FT)"),
        "case"                         => q("nonhydrostatic_box"),
        "pressure_solver"              => q(nameof(typeof(model.pressure_solver))),
        "float_type"                   => q(FT),
        "grid_size"                    => "[$Nx, $Ny, $Nz]",
        "ranks"                        => string(nranks),
        "partition"                    => q("$(nranks)x1x1"),
        "communication"                => q(comm_name),
        "weak_scaling"                 => string(weak),
        "dt"                           => string(Δt),
        "time_steps"                   => string(nsteps),
        "samples"                      => string(nwindows),
        "time_per_step_seconds"        => string(tmin),
        "time_per_step_median_seconds" => string(tmed),
        "time_per_step_max_seconds"    => string(tmax),
        "grid_points_per_second"       => string(ncells / tmin),
        "gpu_memory_used"              => string(memory),
        "finite"                       => string(all_ok),
        "shared_gpu"                   => string(shared),
        "gpu_name"                     => q(gpu),
        "julia_version"                => q(VERSION),
        "oceananigans_version"         => q(pkgversion(Oceananigans)),
        "hostname"                     => q(gethostname()),
        "timestamp"                    => q(now()),
    ]
    open(output, "w") do io
        println(io, "{")
        for (i, (k, v)) in enumerate(fields)
            println(io, "  ", q(k), ": ", v, i < length(fields) ? "," : "")
        end
        println(io, "}")
    end
    println("wrote ", output)
end

all_ok || error("non-finite values after the benchmark: the time step may be too large")

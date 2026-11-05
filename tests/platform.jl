# Platform tests, all in ONE Julia process (packages loaded and kernels compiled once).
# Run on 1, 2 or 4 GPUs (one MPI rank per GPU, grid split in x); tools/run_tests.sh does this.
# Each test prints one line:   TEST <name> <PASS|FAIL|SKIP> <seconds> <detail>
#
#   load          packages load, versions, GPU works, MPI starts                       (all)
#   grids         uniform / stretched-z / lat-lon / immersed grids on the GPU          (1 GPU)
#   single_mpi    one MPI only, the system OpenMPI, with NetCDF loaded                 (all)
#   cuda_aware    a different GPU per rank (as Oceananigans picks it), GPU arrays through MPI (2+)
#   halo          distributed ∂x equals the single-GPU result                          (2+ GPUs)
#   output        NetCDF and JLD2 written and read back under MPI                      (all)
#   hydro_channel hydrostatic, periodic x / walls y (jet-like): steps; 2+ GPUs match the 1-GPU run
#   hydro_box     hydrostatic, bounded x, y, z (vortex-like):   steps; 2+ GPUs match the 1-GPU run
#   checkpoint    run 20 steps = run 10, checkpoint, restart, run 10 more             (all)
#   nh_fft        nonhydrostatic, FFT solver: steps; 2+ GPUs match the 1-GPU run
#   nh_ft         nonhydrostatic, stretched z, Fourier-tridiagonal: steps; 2+ GPUs match 1 GPU
#
# "Match the 1-GPU run": the 1-GPU run saves its fields to $TEST_REF_DIR; the multi-GPU runs compare
# their part with it (relative difference < 1e-8; typically ~1e-14). Without a reference: SKIP.

using Oceananigans, CUDA, MPI, NCDatasets, JLD2
using Oceananigans.BoundaryConditions: fill_halo_regions!
using Libdl, Printf
import OpenMPI_jll
include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()

const comm   = MPI.COMM_WORLD
const rank   = MPI.Comm_rank(comm)
const nranks = MPI.Comm_size(comm)
const refdir = get(ENV, "TEST_REF_DIR", joinpath(ENV["OCEAN_HPC_ROOT"], "logs", "tests_ref"))
const tol    = 1e-8
rank == 0 && mkpath(refdir)
MPI.Barrier(comm)

arch_for(n) = n == 1 ? GPU() : Distributed(GPU(); partition = Partition(n, 1, 1))
all_ranks(ok::Bool) = MPI.Allreduce(ok ? 1 : 0, MPI.MIN, comm) == 1
gmax(x) = MPI.Allreduce(x, MPI.MAX, comm)

failures = 0
function run_test(f, name)
    t0 = time()
    status, detail = try
        f()
    catch err
        ("FAIL", "ERROR: " * first(split(sprint(showerror, err), '\n')))
    end
    status = all_ranks(status != "FAIL") ? status : "FAIL"     # FAIL if any rank failed
    status == "FAIL" && (global failures += 1)
    rank == 0 && (@printf("TEST %s %s %.0f %s\n", name, status, time() - t0, detail); flush(stdout))
    MPI.Barrier(comm)
end

# ---- reference fields: saved by the 1-GPU run, compared by the multi-GPU runs -------------------
reffile(name) = joinpath(refdir, name * ".jld2")
pf(ok::Bool) = ok ? "PASS" : "FAIL"

# fields: NamedTuple of fields that are Center in x (so the global array splits evenly in x)
function save_or_compare(name, fields, arch)
    if nranks == 1
        jldsave(reffile(name); (k => Array(interior(f)) for (k, f) in pairs(fields))...)
        return "PASS", "1 GPU; reference saved"
    end
    isfile(reffile(name)) || return "SKIP", "steps OK; no 1-GPU reference (run with 1 GPU first)"
    ref = JLD2.load(reffile(name))
    worst = 0.0
    for (k, f) in pairs(fields)
        R    = ref[string(k)]
        mine = Array(interior(f))
        part = R[(arch.local_index[1]-1)*size(mine, 1) .+ (1:size(mine, 1)), :, :]
        err  = gmax(maximum(abs, mine .- part))
        scl  = gmax(maximum(abs, R))
        worst = max(worst, scl > 0 ? err / scl : err)
    end
    return pf(worst < tol), @sprintf("%d GPUs vs 1 GPU: max relative difference %.1e", nranks, worst)
end

steps!(model, n, Δt) = (for _ in 1:n; time_step!(model, Δt); end; CUDA.synchronize())
finite(fields...) = all_ranks(all(f -> all(isfinite, interior(f)), fields))

# ---- tests --------------------------------------------------------------------------------------
run_test("load") do
    ok = CUDA.functional() && sum(CUDA.ones(Float64, 10^6)) == 10^6
    if rank == 0
        println("julia         ", VERSION)
        for (k, m) in (("Oceananigans", Oceananigans), ("CUDA", CUDA), ("MPI", MPI), ("NCDatasets", NCDatasets),
                       ("JLD2", JLD2), ("OpenMPI_jll", OpenMPI_jll))
            println(rpad(k, 14), pkgversion(m))
        end
        println("GPU           ", CUDA.name(CUDA.device()), ", ", round(CUDA.total_memory() / 2^30, digits = 1), " GiB")
    end
    return pf(ok), "$nranks rank(s); $(CUDA.name(CUDA.device()))"
end

if nranks == 1
    run_test("grids") do
        arch = GPU()
        stretched(k) = -1000 * (1 - tanh(1.5 * (k - 1) / 16) / tanh(1.5))
        base = RectilinearGrid(arch; size = (32, 32, 16), x = (0, 1e5), y = (0, 1e5), z = (-1000, 0),
                               topology = (Periodic, Periodic, Bounded))
        bump(x, y) = -1000 + 300 * exp(-((x - 5e4)^2 + (y - 5e4)^2) / 2e4^2)
        grids = (RectilinearGrid(arch; size = (32, 32, 16), x = (0, 1e5), y = (0, 1e5), z = (-1000, 0),
                                 topology = (Periodic, Bounded, Bounded)),
                 RectilinearGrid(arch; size = (32, 32, 16), x = (-5e4, 5e4), y = (-5e4, 5e4), z = stretched,
                                 topology = (Bounded, Bounded, Bounded)),
                 LatitudeLongitudeGrid(arch; size = (36, 18, 8), longitude = (0, 360), latitude = (-75, 75), z = (-4000, 0)),
                 ImmersedBoundaryGrid(base, GridFittedBottom(bump)))
        ok = map(grids) do g
            c = CenterField(g); set!(c, (x, y, z) -> sin(x / 1e3) + z / 1e3)
            d = Field(∂x(c)); compute!(d)
            all(isfinite, interior(d))
        end
        return pf(all(ok)), "$(count(ok)) of $(length(ok)) grid types"
    end
end

run_test("single_mpi") do
    libs = filter(l -> occursin(r"libmpi\.so|libopen-pal|libopen-rte|/mca_", l), Libdl.dllist())
    foreign = filter(l -> occursin("/artifacts/", l), libs)
    detail = isempty(foreign) ? "system OpenMPI only ($(get(ENV, "OPAL_PREFIX", "?")))" :
                                "Julia's own MPI loaded: $(first(foreign))"
    return pf(isempty(foreign)), detail
end

if nranks > 1
    run_test("cuda_aware") do
        # Let Oceananigans choose the GPU, as in a real run: with one GPU per task (Nibi, Fir,
        # Rorqual) each rank sees only its own; when a rank sees all the node's GPUs (Trillium,
        # run_local --all-visible) Distributed(GPU()) picks one by node-local rank.
        arch_for(nranks)
        nvis = length(CUDA.devices())
        uuid = string(CUDA.uuid(CUDA.device()))
        dest, source = mod(rank + 1, nranks), mod(rank - 1, nranks)
        send, recv = CUDA.fill(Float64(rank), 10^6), CUDA.zeros(Float64, 10^6)
        MPI.Sendrecv!(send, recv, comm; dest, source)
        ok = all_ranks(all(Array(recv) .== source))
        uuids = MPI.gather(uuid, comm; root = 0)                  # strings: gather to rank 0
        ndistinct = rank == 0 ? length(unique(uuids)) : nranks
        distinct = ndistinct == nranks
        detail = "$nranks ranks on $ndistinct different GPU(s) ($nvis visible per rank); " *
                 (ok ? "GPU arrays through MPI OK" : "MPI exchange of GPU arrays WRONG")
        return pf(ok && distinct), detail
    end

    run_test("halo") do
        N = (64, 32, 8); topo = (Periodic, Periodic, Bounded)
        f(x, y, z) = sin(2π * x) * cos(2π * y) * (1 + z)
        arch = arch_for(nranks)
        g = RectilinearGrid(arch; size = N, x = (0, 1), y = (0, 1), z = (0, 1), topology = topo)
        c = CenterField(g); set!(c, f); fill_halo_regions!(c)
        d = Field(∂x(c)); compute!(d)
        gs = RectilinearGrid(GPU(); size = N, x = (0, 1), y = (0, 1), z = (0, 1), topology = topo)
        cs = CenterField(gs); set!(cs, f); fill_halo_regions!(cs)
        ds = Field(∂x(cs)); compute!(ds)
        mine = Array(interior(d)); nx = size(mine, 1)
        ref = Array(interior(ds))[(arch.local_index[1]-1)*nx .+ (1:nx), :, :]
        err = gmax(maximum(abs, mine .- ref)) / gmax(maximum(abs, ref))
        return pf(err < 1e-12), @sprintf("max relative difference %.1e", err)
    end
end

run_test("output") do
    dir = mktempdir()
    data = rand(8, 8) .+ rank
    nc = joinpath(dir, "t.nc")
    NCDataset(nc, "c") do ds
        defDim(ds, "x", 8); defDim(ds, "y", 8)
        defVar(ds, "a", Float64, ("x", "y"))[:, :] = data
    end
    jl = joinpath(dir, "t.jld2"); jldsave(jl; data)
    ok = NCDataset(ds -> ds["a"][:, :], nc) == data && JLD2.load(jl, "data") == data
    return pf(ok), "NetCDF and JLD2 on every rank"
end

# ---- hydrostatic models -------------------------------------------------------------------------
# 128 cells in x: 32 per rank on 4 GPUs, more than the 16-cell halo the split-explicit free surface
# extends into with 20 substeps (with 64, Oceananigans warns that results may be wrong).
const Nh = (128, 32, 16)

function hydro_channel(arch)
    Lx, Ly = 640e3, 320e3
    g = RectilinearGrid(arch; size = Nh, halo = (4, 4, 4), x = (0, Lx), y = (-Ly / 2, Ly / 2), z = (-1000, 0),
                        topology = (Periodic, Bounded, Bounded))
    m = HydrostaticFreeSurfaceModel(g; momentum_advection = WENO(order = 5), tracer_advection = WENO(order = 5),
                                    buoyancy = BuoyancyTracer(), tracers = :b, coriolis = FPlane(f = 1e-4),
                                    free_surface = SplitExplicitFreeSurface(g; substeps = 20),
                                    timestepper = :SplitRungeKutta3)
    set!(m, b = (x, y, z) -> 1e-4 * z + 2e-3 * tanh(y / 50e3) * exp(z / 300) +
                             1e-5 * sin(2π * x / Lx) * exp(-(y / 50e3)^2))
    return m
end

function hydro_box(arch)
    L = 640e3
    g = RectilinearGrid(arch; size = Nh, halo = (4, 4, 4), x = (-L / 2, L / 2), y = (-L / 4, L / 4), z = (-1000, 0),
                        topology = (Bounded, Bounded, Bounded))
    m = HydrostaticFreeSurfaceModel(g; momentum_advection = WENO(order = 5), tracer_advection = WENO(order = 5),
                                    buoyancy = BuoyancyTracer(), tracers = :b, coriolis = FPlane(f = 1.4e-4),
                                    free_surface = SplitExplicitFreeSurface(g; substeps = 20),
                                    timestepper = :SplitRungeKutta3)
    set!(m, b = (x, y, z) -> 1e-4 * z - 2e-3 * exp(-(x^2 + y^2) / 80e3^2) * exp(z / 300) +
                             1e-5 * cos(3 * atan(y, x)) * exp(-(x^2 + y^2) / 80e3^2))
    return m
end

for (name, build) in (("hydro_channel", hydro_channel), ("hydro_box", hydro_box))
    run_test(name) do
        arch = arch_for(nranks)
        m = build(arch)
        steps!(m, 30, 300.0)
        u, v, w, b = m.velocities..., m.tracers.b
        finite(u, v, w, b) || return "FAIL", "non-finite values after 30 steps"
        gmax(maximum(abs, interior(u))) > 0 || return "FAIL", "no flow developed"
        save_or_compare(name, (v = v, w = w, b = b), arch)
    end
end

run_test("checkpoint") do
    arch = arch_for(nranks)
    dir = joinpath(refdir, "checkpoint_$(nranks)gpu")
    rank == 0 && (rm(dir; force = true, recursive = true); mkpath(dir))
    MPI.Barrier(comm)
    # A: 20 steps straight, checkpointing at 10 and 20
    m1 = hydro_channel(arch)
    s1 = Simulation(m1; Δt = 300.0, stop_iteration = 20, verbose = false)
    s1.output_writers[:checkpointer] = Checkpointer(m1; schedule = IterationInterval(10), dir, prefix = "ckpt")
    run!(s1)
    # B: a fresh model, restarted from the iteration-10 checkpoint, run to 20
    m2 = hydro_channel(arch)
    s2 = Simulation(m2; Δt = 300.0, stop_iteration = 20, verbose = false)
    s2.output_writers[:checkpointer] = Checkpointer(m2; schedule = IterationInterval(10), dir, prefix = "ckpt")
    run!(s2; pickup = 10)
    m2.clock.iteration == 20 || return "FAIL", "restarted run ended at iteration $(m2.clock.iteration)"
    worst = 0.0
    for (a, b) in ((m1.velocities.u, m2.velocities.u), (m1.velocities.v, m2.velocities.v), (m1.tracers.b, m2.tracers.b))
        A, B = Array(interior(a)), Array(interior(b))
        worst = max(worst, gmax(maximum(abs, A .- B)) / gmax(maximum(abs, A)))
    end
    detail = @sprintf("restart vs straight run: max relative difference %.1e", worst)
    return pf(worst < 1e-12), worst == 0 ? detail * " (bitwise)" : detail
end

# ---- nonhydrostatic models ----------------------------------------------------------------------
function nh_box(arch, stretched::Bool)
    Lx = Ly = 1000.0; Lz = 500.0; N = (64, 64, 32)
    z = stretched ? ExponentialDiscretization(N[3], -Lz, 0; scale = Lz / 2) : (-Lz, 0)
    g = RectilinearGrid(arch; size = N, halo = (4, 4, 4), x = (0, Lx), y = (0, Ly), z,
                        topology = (Periodic, Periodic, Bounded))
    m = NonhydrostaticModel(g; advection = WENO(order = 5), coriolis = FPlane(f = 1e-4),
                            buoyancy = BuoyancyTracer(), tracers = :b)
    set!(m, u = (x, y, z) -> 0.05 + 0.005 * sin(6π * x / Lx) * cos(4π * y / Ly) * cos(π * z / Lz),
            v = (x, y, z) -> 0.005 * cos(4π * x / Lx) * sin(6π * y / Ly) * cos(π * z / Lz),
            b = (x, y, z) -> 1e-5 * z)
    return m
end

for (name, stretched) in (("nh_fft", false), ("nh_ft", true))
    run_test(name) do
        arch = arch_for(nranks)
        m = nh_box(arch, stretched)
        steps!(m, 10, 5.0)
        u, v, w, b = m.velocities..., m.tracers.b
        finite(u, v, w, b) || return "FAIL", "non-finite values after 10 steps"
        status, detail = save_or_compare(name, (v = v, w = w, b = b), arch)
        return status, detail * " (" * string(nameof(typeof(m.pressure_solver))) * ")"
    end
end

rank == 0 && println("SUMMARY $(failures == 0 ? "PASS" : "FAIL") $failures failure(s) on $nranks GPU(s)")
MPI.Barrier(comm)
failures == 0 || exit(1)

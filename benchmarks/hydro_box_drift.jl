# TEMPORARY (remove before #37 merges). Does the platform test hydro_box's 4-GPU vs 1-GPU difference
# (0 on Oceananigans 0.113.5, 5.2e-14 on 0.116.1, Oct 26) grow, and how? On pelee/rondeau, after
# sourcing the ocean_setup of the environment to test:
#
#     bash $OCEAN_HPC_ROOT/tools/run_local.sh --wait --gpus 4 --project $OCEAN_HPC_ROOT --job-name drift <this file>
#
# One MPI run on 4 GPUs. All ranks step hydro_box (as in tests/platform.jl) split in x; rank 0 also
# steps it on 1 GPU, twice: as is (the reference) and with the initial buoyancy changed by one rounding
# unit (the control). At 30, 100, 300, 1000 and 3000 steps it prints:
#   four_vs_one   max |4 GPUs - 1 GPU| / max |1 GPU| over v, w, b
#   control       the same for the 1-ulp control against the reference: round-off amplified by the flow
#   at_i          x index (1-64) of the largest 4-vs-1 difference in b; ranks meet between 16|17, 32|33, 48|49
# Round-off: four_vs_one stays at or below control and at_i is not tied to the rank boundaries.

using Oceananigans, CUDA, MPI, Printf
include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()
const comm = MPI.COMM_WORLD
const rank = MPI.Comm_rank(comm)
const nranks = MPI.Comm_size(comm)

const Nh = (64, 32, 16)
function hydro_box(arch; δ = 0.0)          # tests/platform.jl's hydro_box, initial b times (1 + δ)
    L = 640e3
    g = RectilinearGrid(arch; size = Nh, halo = (4, 4, 4), x = (-L / 2, L / 2), y = (-L / 4, L / 4), z = (-1000, 0),
                        topology = (Bounded, Bounded, Bounded))
    m = HydrostaticFreeSurfaceModel(g; momentum_advection = WENO(order = 5), tracer_advection = WENO(order = 5),
                                    buoyancy = BuoyancyTracer(), tracers = :b, coriolis = FPlane(f = 1.4e-4),
                                    free_surface = SplitExplicitFreeSurface(g; substeps = 20),
                                    timestepper = :SplitRungeKutta3)
    set!(m, b = (x, y, z) -> (1 + δ) * (1e-4 * z - 2e-3 * exp(-(x^2 + y^2) / 80e3^2) * exp(z / 300) +
                                        1e-5 * cos(3 * atan(y, x)) * exp(-(x^2 + y^2) / 80e3^2)))
    return m
end
fields(m) = (Array(interior(m.velocities.v)), Array(interior(m.velocities.w)), Array(interior(m.tracers.b)))

# the distributed fields, put together on rank 0 in x order
function gathered(m, arch)
    out = map(fields(m)) do a
        blocks = MPI.Gather(vec(a), comm; root = 0)
        idx    = MPI.Gather([arch.local_index[1]], comm; root = 0)
        rank == 0 || return nothing
        n = length(a)
        parts = [reshape(blocks[(r - 1) * n + 1:r * n], size(a)) for r in 1:nranks]
        cat(parts[sortperm(idx)]...; dims = 1)
    end
    return out
end
reldiff(A, B) = maximum(maximum(abs, a .- b) / maximum(abs, b) for (a, b) in zip(A, B))

arch = Distributed(GPU(); partition = Partition(nranks, 1, 1))
md = hydro_box(arch)
if rank == 0
    m1 = hydro_box(GPU())
    mc = hydro_box(GPU(); δ = eps(Float64))
    @printf("hydro_box drift: Oceananigans %s, Julia %s, %d GPUs vs 1\n", pkgversion(Oceananigans), VERSION, nranks)
    @printf("%6s %13s %13s %6s\n", "steps", "four_vs_one", "control", "at_i")
end

done = 0
for target in (30, 100, 300, 1000, 3000)
    for _ in done+1:target
        time_step!(md, 300.0)
        rank == 0 && (time_step!(m1, 300.0); time_step!(mc, 300.0))
    end
    global done = target
    CUDA.synchronize()
    G = gathered(md, arch)
    if rank == 0
        R = fields(m1)
        i = argmax(abs.(G[3] .- R[3]))[1]
        @printf("%6d %13.2e %13.2e %6d\n", target, reldiff(G, R), reldiff(fields(mc), R), i)
        flush(stdout)
    end
    MPI.Barrier(comm)
end

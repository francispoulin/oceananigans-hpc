# Where and when do 1-GPU and N-GPU runs of the platform's hydrostatic channel differ?
# (Diagnosis of the 0.118.2 failure on Trillium, Nov 27, 2026: hydro_channel and hydro_box,
# 4 GPUs vs 1 GPU differ by 17-25% after 30 steps.) The model is tests/platform.jl's hydro_channel,
# with the substeps, Nx and time stepper as arguments. Run by diag_hydro_split.sh:
#
#   srun -n N julia --project=$WT diag_hydro_split.jl run OUTDIR TAG SUBSTEPS NX TIMESTEPPER
#   julia --project=$WT diag_hydro_split.jl compare OUTDIR TAG N
#
# run saves u, v, w, b, η on every rank after steps 1, 2, 5 and 30; compare joins the N ranks in x
# and prints, per step and field, the largest relative difference from the 1-GPU run, where it is,
# and which x columns differ at all (rank boundaries are at multiples of NX/N).

using Oceananigans, MPI, CUDA, JLD2, Printf

const STEPS = (1, 2, 5, 30)
const FIELDS = (:u, :v, :w, :b, :η)

function run_case(outdir, tag, substeps, Nx, ts)
    MPI.Initialized() || MPI.Init()
    nr = MPI.Comm_size(MPI.COMM_WORLD); rank = MPI.Comm_rank(MPI.COMM_WORLD)
    arch = nr == 1 ? GPU() : Distributed(GPU(); partition = Partition(nr, 1, 1))
    Lx, Ly = 640e3, 320e3
    g = RectilinearGrid(arch; size = (Nx, 32, 16), halo = (4, 4, 4), x = (0, Lx), y = (-Ly / 2, Ly / 2),
                        z = (-1000, 0), topology = (Periodic, Bounded, Bounded))
    m = HydrostaticFreeSurfaceModel(g; momentum_advection = WENO(order = 5), tracer_advection = WENO(order = 5),
                                    buoyancy = BuoyancyTracer(), tracers = :b, coriolis = FPlane(f = 1e-4),
                                    free_surface = SplitExplicitFreeSurface(g; substeps), timestepper = ts)
    set!(m, b = (x, y, z) -> 1e-4 * z + 2e-3 * tanh(y / 50e3) * exp(z / 300) +
                             1e-5 * sin(2π * x / Lx) * exp(-(y / 50e3)^2))
    for n in 1:maximum(STEPS)
        time_step!(m, 300.0)
        n in STEPS || continue
        CUDA.synchronize()
        f = (u = m.velocities.u, v = m.velocities.v, w = m.velocities.w, b = m.tracers.b, η = m.free_surface.displacement)
        jldsave(joinpath(outdir, "$(tag)_$(nr)gpu_step$(n)_rank$(rank).jld2"); (k => Array(interior(f[k])) for k in FIELDS)...)
    end
    rank == 0 && println("$tag on $nr GPU(s): done (substeps $substeps, Nx $Nx, $ts)")
end

"Consecutive integers as ranges: [1, 2, 3, 7] -> \"1-3, 7\""
function ranges(is)
    isempty(is) && return "none"
    r = Tuple{Int,Int}[]
    for i in is
        if isempty(r) || i != r[end][2] + 1
            push!(r, (i, i))
        else
            r[end] = (r[end][1], i)
        end
    end
    return join([a == b ? "$a" : "$a-$b" for (a, b) in r], ", ")
end

function compare(outdir, tag, N)
    for n in STEPS
        one = JLD2.load(joinpath(outdir, "$(tag)_1gpu_step$(n)_rank0.jld2"))
        parts = [JLD2.load(joinpath(outdir, "$(tag)_$(N)gpu_step$(n)_rank$(r).jld2")) for r in 0:N-1]
        Nx = size(one["b"], 1)
        println("== $tag, step $n: $N GPUs vs 1 GPU (rank boundaries after x cells ", join((Nx ÷ N) .* (1:N-1), ", "), ")")
        for k in string.(FIELDS)
            A = one[k]; B = cat((p[k] for p in parts)...; dims = 1)
            d = abs.(B .- A); scl = maximum(abs, A)
            rel = scl > 0 ? maximum(d) / scl : maximum(d)
            cols = [i for i in axes(d, 1) if maximum(view(d, i, :, :)) > 1e-12 * max(scl, eps())]
            @printf("  %-2s max relative difference %.2e at %s; x columns that differ: %s\n",
                    k, rel, Tuple(argmax(d)), ranges(cols))
        end
    end
end

if ARGS[1] == "run"
    run_case(ARGS[2], ARGS[3], parse(Int, ARGS[4]), parse(Int, ARGS[5]), Symbol(ARGS[6]))
elseif ARGS[1] == "compare"
    compare(ARGS[2], ARGS[3], parse(Int, ARGS[4]))
else
    error("usage: diag_hydro_split.jl run OUTDIR TAG SUBSTEPS NX TIMESTEPPER | compare OUTDIR TAG N")
end

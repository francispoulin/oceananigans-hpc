# NCCL alltoall bandwidth: time the NCCL exchange that Oceananigans' NCCL extension does in each
# transpose of the distributed Poisson solvers (OceananigansNCCLExt/nccl_transpose.jl:
# a local copyto! of the rank's own chunk, then ncclSend/ncclRecv to every other rank inside one
# NCCL group, complex numbers sent as 2x their real type), without the rest of the model.
#
# The NCCL counterpart of alltoall_bandwidth.jl (which times MPI.Alltoall!). Sizes are PER GPU
# (weak scaling), so the default 512^3 matches the Nsight kernel-scaling captures of Nov 2026.
# Both complex types are timed: ComplexF64 (Oceananigans' nonhydrostatic box, Float64) and
# ComplexF32 (Breeze benchmarks, Float32 by default).
#
# Run with the NCCL environment (setup/setup_nccl_env.sh), in both GPU-visibility modes, with
# NCCL_DEBUG=INFO so the log says which transport NCCL picked (P2P/IPC over NVLink, or SHM):
#
#   cd $OCEAN_HPC_ROOT
#   export NCCL_DEBUG=INFO
#   bash tools/run_local.sh --wait --gpus 2 --project envs/nccl --job-name nccl_a2a_own benchmarks/nccl_alltoall_bandwidth.jl
#   bash tools/run_local.sh --wait --gpus 2 --project envs/nccl --all-visible --job-name nccl_a2a_all benchmarks/nccl_alltoall_bandwidth.jl
#   unset NCCL_DEBUG
#   grep -h "^RESULT" logs/nccl_a2a_*.out
#   grep -h " via " logs/nccl_a2a_*.out | sort | uniq -c
#
# Environment: NX NY NZ cells per GPU (default 512 512 512), NTRIALS (default 20).
# Prints RESULT lines (rank 0): time per transpose (with and without the local copy) and the
# bandwidth of the part that leaves the GPU.

using CUDA, NCCL
using Statistics, Printf
include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()

comm = MPI.COMM_WORLD
rank = MPI.Comm_rank(comm)
P    = MPI.Comm_size(comm)
P > 1 || error("run with at least 2 ranks (--gpus 2)")

# One GPU per rank: if the rank sees several GPUs (--all-visible), pick by node-local rank,
# as Oceananigans' Distributed(GPU()) does.
local_comm = MPI.Comm_split_type(comm, MPI.COMM_TYPE_SHARED, rank)
local_rank = MPI.Comm_rank(local_comm)
nvisible   = length(CUDA.devices())
CUDA.device!(mod(local_rank, nvisible))

getint(name, default) = parse(Int, get(ENV, name, string(default)))
Nx, Ny, Nz = getint("NX", 512), getint("NY", 512), getint("NZ", 512)
ntrials    = getint("NTRIALS", 20)

# NCCL communicator from MPI, as OceananigansNCCLExt/nccl_communicator.jl does it
function nccl_comm_from_mpi(comm)
    n, r = MPI.Comm_size(comm), MPI.Comm_rank(comm)
    id_bytes = Vector{Cchar}(undef, 128)
    if r == 0
        id_ref = Ref(NCCL.UniqueID().internal)
        GC.@preserve id_ref unsafe_copyto!(pointer(id_bytes), Ptr{Cchar}(pointer_from_objref(id_ref)), 128)
    end
    MPI.Bcast!(id_bytes, comm; root=0)
    MPI.Barrier(comm)
    id = NCCL.UniqueID(ntuple(i -> id_bytes[i], Val(128)))
    return NCCL.Communicator(n, r; unique_id=id)
end

nccl = nccl_comm_from_mpi(comm)

# Same as OceananigansNCCLExt.nccl_alltoall! (local_copy=false: only the part that leaves the GPU)
function nccl_alltoall!(send, recv, count, nccl, me, P; local_copy=true)
    local_copy && copyto!(recv, me * count + 1, send, me * count + 1, count)
    T = eltype(send)
    n = T <: Complex ? 2count : count
    datatype = NCCL.ncclDataType_t(T <: Complex ? real(T) : T)
    stream = CUDA.stream()
    NCCL.groupStart()
    for r in 0:(P - 1)
        r == me && continue
        NCCL.LibNCCL.ncclSend(pointer(send, r * count + 1), n, datatype, Int32(r), nccl.handle, stream)
        NCCL.LibNCCL.ncclRecv(pointer(recv, r * count + 1), n, datatype, Int32(r), nccl.handle, stream)
    end
    NCCL.groupEnd()
    return nothing
end

function timed!(send, recv, count; local_copy)
    CUDA.synchronize()
    MPI.Barrier(comm)
    t0 = MPI.Wtime()
    nccl_alltoall!(send, recv, count, nccl, rank, P; local_copy)
    CUDA.synchronize()
    return MPI.Wtime() - t0
end

if rank == 0
    println("GPU: ", CUDA.name(CUDA.device()), "   GPUs visible per rank: ", nvisible,
            "   ranks: ", P, "   cells per GPU: $(Nx)x$(Ny)x$(Nz)")
end

for T in (ComplexF64, ComplexF32)
    n_local = Nx * Ny * Nz          # complex elements each rank holds (its pressure storage)
    count   = n_local ÷ P           # elements sent to each destination (equal chunks)
    send = CuArray(T.(rank * 10^6 .+ (1:count * P) .% 10^6))   # tagged, exact in Float32
    recv = similar(send)

    for _ in 1:3
        timed!(send, recv, count; local_copy=true)        # warm-up (connections, buffers)
    end
    t_full = [MPI.Allreduce(timed!(send, recv, count; local_copy=true),  max, comm) for _ in 1:ntrials]
    t_net  = [MPI.Allreduce(timed!(send, recv, count; local_copy=false), max, comm) for _ in 1:ntrials]

    # Correctness: chunk `src` of recv holds chunk `rank` of src's send buffer
    src = mod(rank + 1, P)
    expected = T(src * 10^6 + (rank * count + 1) % 10^6)
    ok = MPI.Allreduce(Int(Array(view(recv, src*count+1:src*count+1))[1] == expected), min, comm) == 1

    bytes_out = sizeof(T) * count * (P - 1)     # bytes each rank sends to other GPUs per transpose
    if rank == 0
        @printf("RESULT nccl_alltoall type=%s ranks=%d visible=%d MB_out_per_rank=%.0f t_full_median_ms=%.2f t_net_median_ms=%.2f t_net_min_ms=%.2f GBps_per_rank=%.1f correct=%s\n",
                T, P, nvisible, bytes_out / 1e6, 1e3 * median(t_full), 1e3 * median(t_net),
                1e3 * minimum(t_net), bytes_out / median(t_net) / 1e9, ok)
    end
    CUDA.unsafe_free!(send); CUDA.unsafe_free!(recv)
    MPI.Barrier(comm)
end

# Destroy the communicator together on every rank before MPI shuts down
CUDA.synchronize()
MPI.Barrier(comm)
NCCL.destroy(nccl)
MPI.Barrier(comm)

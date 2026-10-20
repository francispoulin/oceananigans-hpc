# Alltoall bandwidth: time the MPI_Alltoall on GPU buffers that Oceananigans' distributed Poisson
# solvers use, at the sizes of benchmarks/nonhydrostatic_box.jl, without the rest of the model.
#
# Why: in the distributed FFT / Fourier-tridiagonal solvers, each transpose packs the complex
# pressure storage into a 1-D GPU buffer, synchronizes, calls MPI.Alltoall! directly on the GPU
# buffers (CUDA-aware MPI), then unpacks. With the grid split in x, each pressure solve does 2
# transposes (y->x and back) and an RK3 step does 3 solves.
#
# Result on pelee (2 x A100-SXM4, NVLink, 512x512x256): 3.45 ms per transpose, ~78 GB/s per GPU,
# the same whether each rank sees only its own GPU (run_local.sh default) or all of them
# (--all-visible). So MPI does copy GPU-to-GPU over NVLink, and the Alltoall explains only ~21 of
# the ~65 ms per step that 2 GPUs lose in nonhydrostatic_box.jl (results/nonhydrostatic_rondeau.md).
# To repeat (e.g. on a new machine or MPI):
#
#   bash tools/run_local.sh --wait --gpus 2 --job-name a2a_2gpu_own benchmarks/alltoall_bandwidth.jl
#   bash tools/run_local.sh --wait --gpus 2 --all-visible --job-name a2a_2gpu_all benchmarks/alltoall_bandwidth.jl
#   (same with -n 4)
#   grep -h "^RESULT" logs/a2a_*.out
#
# Environment: NX NY NZ (default 512 512 256, the strong-scaling case), NTRIALS (default 20).
# Prints one RESULT line per run (rank 0).

using CUDA
using Statistics, Printf
include(joinpath(ENV["OCEAN_HPC_ROOT"], "src", "drac_mpi.jl"))
drac_mpi_init()

comm = MPI.COMM_WORLD
rank = MPI.Comm_rank(comm)
P    = MPI.Comm_size(comm)

# One GPU per rank: if the rank sees several GPUs (--all-visible), pick by node-local rank,
# as Oceananigans' Distributed(GPU()) does.
local_comm = MPI.Comm_split_type(comm, MPI.COMM_TYPE_SHARED, rank)
local_rank = MPI.Comm_rank(local_comm)
nvisible   = length(CUDA.devices())
CUDA.device!(mod(local_rank, nvisible))

getint(name, default) = parse(Int, get(ENV, name, string(default)))
Nx, Ny, Nz = getint("NX", 512), getint("NY", 512), getint("NZ", 256)
ntrials    = getint("NTRIALS", 20)

count   = (Nx * Ny * Nz ÷ P) ÷ P   # ComplexF64 elements sent to each destination (equal chunks)
n_local = count * P                # elements held by each rank (its share of the global field)

# Tagged values: element k of rank r's send buffer is r*10^9 + k (exact in Float64)
send = CuArray(ComplexF64.(rank * 10^9 .+ (1:n_local)))
recv = similar(send)

function one_alltoall!(send, recv, count, comm)
    CUDA.synchronize()
    MPI.Barrier(comm)
    t0 = MPI.Wtime()
    MPI.Alltoall!(MPI.UBuffer(send, count), MPI.UBuffer(recv, count), comm)
    CUDA.synchronize()
    return MPI.Wtime() - t0
end

for _ in 1:3
    one_alltoall!(send, recv, count, comm)   # warm-up (IPC handles, registration caches)
end
times = [MPI.Allreduce(one_alltoall!(send, recv, count, comm), max, comm) for _ in 1:ntrials]

# Correctness: chunk `src` of recv holds chunk `rank` of src's send buffer
src      = mod(rank + 1, P)
expected = ComplexF64(src * 10^9 + rank * count + 1)
ok = MPI.Allreduce(Int(Array(view(recv, src*count+1:src*count+1))[1] == expected), min, comm) == 1

# Can this GPU reach the others directly? Only answerable when they are visible.
peer = "n/a (1 GPU visible)"
if nvisible > 1
    me = CUDA.device()
    peer = try
        all(CUDA.can_access_peer(me, d) for d in CUDA.devices() if d != me) ? "yes" : "NO"
    catch
        "unknown"
    end
end

bytes_out = 16 * count * (P - 1)       # bytes each rank sends to other GPUs per transpose
t_med, t_min = median(times), minimum(times)

if rank == 0
    # (the version string can end in NUL characters, which make grep treat the log as binary)
    println("MPI library: ", first(split(strip(replace(MPI.Get_library_version(), '\0' => "")), '\n')))
    println("MPI.has_cuda(): ", MPI.has_cuda(), "   GPU: ", CUDA.name(CUDA.device()),
            "   GPUs visible per rank: ", nvisible, "   peer access: ", peer)
    @printf("RESULT alltoall ranks=%d visible=%d grid=%dx%dx%d MB_out_per_rank=%.0f t_median_ms=%.2f t_min_ms=%.2f GBps_per_rank=%.1f correct=%s\n",
            P, nvisible, Nx, Ny, Nz, bytes_out / 1e6, 1e3 * t_med, 1e3 * t_min,
            bytes_out / t_med / 1e9, ok)
    @printf("=> per pressure solve (2 transposes): %.1f ms; per RK3 step (3 solves): %.1f ms\n",
            2e3 * t_med, 6e3 * t_med)
end

MPI.Barrier(comm)
ok || exit(1)

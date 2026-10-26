# Benchmarks

## `nonhydrostatic_box.jl`

Time per step of a `NonhydrostaticModel` on 1, 2, 4, ... GPUs (one MPI rank per GPU, grid split in
x), to see how the nonhydrostatic pressure solve scales. Configuration copied from the
`nonhydrostatic` case of the newer Oceananigans benchmark suite (main branch), adapted to the
Oceananigans version in this repository (0.113.5) and to multiple GPUs:
1 km x 1 km x 500 m box, periodic in x and y, WENO(5), f-plane, stratified buoyancy tracer.

| `--solver` | Grid | 1 GPU | several GPUs |
| --- | --- | --- | --- |
| `FFT` | uniform | `FFTBasedPoissonSolver` | `DistributedFFTBasedPoissonSolver` (transposes) |
| `FourierTridiagonal` | stretched in z | `FourierTridiagonalPoissonSolver` | `DistributedFourierTridiagonalPoissonSolver` |
| `ConjugateGradient` | seamount (immersed) | FFT-preconditioned CG | not supported here |

Constraints of the distributed solvers: no split in z; Ny divisible by the number of GPUs.

**pelee / rondeau** (strong scaling 1, 2, 4 GPUs; each run waits for the previous one):

```bash
cd $OCEAN_HPC_ROOT
for n in 1 2 4; do
    bash tools/run_local.sh --wait --gpus $n --job-name nh_fft_${n}gpu benchmarks/nonhydrostatic_box.jl --solver=FFT || break
done
grep -h "^RESULT" logs/nh_fft_*gpu_*.out
```

**Alliance:** `sbatch --ntasks-per-node=2 jobs/benchmark_nh.sh` (options in that file).

Every run prints one `RESULT ...` line (time per step: fastest, median, slowest window; cells/s;
GPU memory) and writes a JSON file to `results/raw/`. The default size, 512 x 512 x 256
(67M cells), fits on one A100-40GB; for weak scaling use `--weak=true` (size per GPU).

Good comparisons: FFT vs FourierTridiagonal at the same size (the stretched-z solver is what a
Beaufort Gyre or Gulf Stream nonhydrostatic run would use), and the same box with the hydrostatic
model (`earth_ocean` case of the Oceananigans suite) for the cost of going nonhydrostatic.

### MPI or NCCL: `--comm=NCCL`

`--comm=NCCL` builds the model on `NCCLDistributed` (transposes and halo exchanges over NCCL). It
needs the NCCL test environment (`setup/setup_nccl_env.sh`, and `--this-machine` on each other
machine). On rondeau, NCCL made the pressure solve ~26% faster on 4 GPUs but ~5% slower on 2
(`poisson_solver.jl`). Full step, 4 GPUs:

```bash
cd $OCEAN_HPC_ROOT
for c in MPI NCCL; do
    bash tools/run_local.sh --wait --gpus 4 --project envs/nccl --job-name nh_FT_${c}_4gpu benchmarks/nonhydrostatic_box.jl \
        --solver=FourierTridiagonal --comm=$c --parts=true --windows=3 || break
done
grep -ah "^RESULT nh" logs/nh_FT_*_4gpu_*.out
```

### Where the time goes: `--parts=true`

Adds a second line, `RESULT nhparts`, with the pieces of a step timed separately: the pressure
solve alone (3 per RK3 step), the pair of transposes it does on several GPUs (pack, MPI Alltoall,
unpack), one halo fill of u, v, w, and the rest of the step (`t_step - 3 t_solve`). Comparing 1
and 2 GPUs shows whether the lost time is in the distributed Poisson solver or in the rest of the model.

```bash
cd $OCEAN_HPC_ROOT
for n in 1 2; do
    for s in FFT FourierTridiagonal; do
        bash tools/run_local.sh --wait --gpus $n --job-name nhparts_${s}_${n}gpu benchmarks/nonhydrostatic_box.jl --solver=$s --parts=true --windows=3 || break 2
    done
done
grep -ah "^RESULT nhparts" logs/nhparts_*.out
```

How to read it: if 2 GPUs scaled perfectly, `t_solve` and `t_rest` would each halve. With an
x-split, `t_solve(2) - t_solve(1)/2` is the solver's overhead, of which `t_transposes_ms` is the
communication part (`alltoall_bandwidth.jl` alone gave ~6.9 ms per solve on pelee); the remainder
is the extra FFT work (three 1-D transforms plus a permutation instead of one batched 2-D FFT).

### Timeline of a step: `--profile=true` with Nsight Systems

`--parts` says how long each piece takes; a profile shows why: every GPU kernel by name (cuFFT,
`_pack_buffer_*`, `_unpack_*`, tendencies), the MPI calls and how long they block, and the gaps
where a GPU waits. With `--profile=true` the benchmark records 2 steps after the warm-up (not the
compilation). On pelee/rondeau (`module load cuda/12.3.2`, done by `ocean_setup`, should provide
`nsys`; check `which nsys`), pick free GPUs with `nvidia-smi`, then from the repository root:

```bash
cd $OCEAN_HPC_ROOT
export JULIA_CUDA_MEMORY_POOL=none
NSYS="nsys profile --trace=cuda,mpi,nvtx --mpi-impl=openmpi --capture-range=cudaProfilerApi --capture-range-end=stop --force-overwrite=true"
ARGS="--solver=FFT --profile=true --windows=1 --steps=10"

# 1 GPU (reference)
CUDA_VISIBLE_DEVICES=0 $NSYS -o logs/nhprof_FFT_1gpu \
    julia --project=. benchmarks/nonhydrostatic_box.jl $ARGS

# 2 GPUs: one report per rank; each rank sees both GPUs and Oceananigans picks one by local rank
CUDA_VISIBLE_DEVICES=0,1 mpiexec -n 2 --bind-to none $NSYS -o logs/nhprof_FFT_2gpu_rank%q{OMPI_COMM_WORLD_RANK} \
    julia --project=. benchmarks/nonhydrostatic_box.jl $ARGS

# Text summaries (paste these; the .nsys-rep files open in the Nsight Systems GUI)
for f in logs/nhprof_FFT_1gpu logs/nhprof_FFT_2gpu_rank0; do
    nsys stats --report cuda_gpu_kern_sum,cuda_api_sum,mpi_event_sum $f.nsys-rep > ${f}_stats.txt
done
```

These run in the foreground (not through `run_local.sh`), so use `screen`/`tmux` if the connection
may drop. If `nsys stats` rejects a report name, `nsys stats --help-reports` lists those available
in that version. Most useful: the kernel summary (total GPU time per kernel, 1 vs 2 GPUs) and the
CUDA API summary (time the host spends waiting in `cuStreamSynchronize`/`cuCtxSynchronize`).

## `tridiagonal_kernel.jl`: one kernel, the batched tridiagonal solve, on one GPU

Times `Oceananigans.Solvers.BatchedTridiagonalSolver` in z alone, on complex numbers (as in the
Fourier-tridiagonal pressure solver) and on real numbers (as in vertically implicit diffusion, e.g.
CATKE), with the versions of Julia, Oceananigans, KernelAbstractions and CUDA. About two minutes.
Run it in each worktree to compare versions (`tools/compare_speed.sh --profile` found this kernel
3.8 times slower with Julia 1.13.2 and Oceananigans 0.116.1, Oct 25):

```bash
CUDA_VISIBLE_DEVICES=0 julia --project=. benchmarks/tridiagonal_kernel.jl     # default 512x512x1024, Float32
```

Alone on an ordinary grid the kernel was only 8–17% slower; inside the 4-GPU run the solution is a
Field (an `OffsetArray` in the kernel), not a plain `CuArray`. `--solution=field` passes it that way, and
`--size=1024x256x1024` is one GPU's array in the 4-GPU run:

```bash
CUDA_VISIBLE_DEVICES=0 julia --project=. benchmarks/tridiagonal_kernel.jl --size=1024x256x1024 --solution=field
```

On Julia 1.13 that is the slow case (Oct 26): complex elements of an `OffsetArray`. `--dump-code=DIR`
writes the compiled kernel (typed Julia, LLVM IR, PTX, SASS) to compare two Julia versions.

## `poisson_solver.jl`: the pressure solver alone, MPI or NCCL

Times `solve_for_pressure!` (source term + distributed Poisson solve, built exactly as
`NonhydrostaticModel` builds it) without the rest of the model, with MPI or Oceananigans'
`NCCLDistributed` for the transposes. Prints `RESULT poisson ...` with the time per solve, the time of
the two transposes, GPU memory, and `p_std` (pressure variation about its mean), which must agree
between 1 and N GPUs and between MPI and NCCL to roundoff (correctness check; `p_mean` may differ,
since pressure is defined up to a constant).

NCCL needs NCCL.jl, which is not in the main environment: make a separate test environment once
(same versions as the main Manifest, plus NCCL; `envs/` is not committed):

```bash
cd $OCEAN_HPC_ROOT
bash setup/setup_nccl_env.sh                  # ~10 min (downloads NCCL, precompiles); ends with "OK: ... loaded"
# on each other machine sharing the folder (e.g. rondeau), once, before multi-GPU runs:
#   bash setup/setup_nccl_env.sh --this-machine
S="--solver=FourierTridiagonal"
bash tools/run_local.sh --wait --gpus 1 --project envs/nccl --job-name poisson_FT_1gpu      benchmarks/poisson_solver.jl $S
bash tools/run_local.sh --wait --gpus 2 --project envs/nccl --job-name poisson_FT_MPI_2gpu  benchmarks/poisson_solver.jl $S --comm=MPI
bash tools/run_local.sh --wait --gpus 2 --project envs/nccl --job-name poisson_FT_NCCL_2gpu benchmarks/poisson_solver.jl $S --comm=NCCL
grep -ah "^RESULT poisson" logs/poisson_FT_*.out
```

If the NCCL run fails with one GPU visible per rank, add `--all-visible`. Profile with Nsight Systems
as for `nonhydrostatic_box.jl` (`--profile=true` records 3 solves), using `--project=envs/nccl`.

### On the Alliance clusters

Once per cluster, on a login node: `bash setup/setup_nccl_env.sh` (makes `envs/nccl`). Then submit
the whole MPI-vs-NCCL set (1 GPU; 2 GPUs; then 1, 2 and 4 full nodes; strong and weak;
17 jobs) and collect the results when they have run:

```bash
cd $OCEAN_HPC_ROOT
DRYRUN=1 bash jobs/submit_poisson_scaling.sh      # check the sbatch commands
bash jobs/submit_poisson_scaling.sh               # or MAXNODES=2 for up to 8 GPUs
grep -ah "^RESULT poisson" logs/p_*.out
```

Single jobs: `jobs/benchmark_poisson.sh` (settings as environment variables; see the file).
On rondeau (4 × A100, NVLink), NCCL was ~5% slower than MPI on 2 GPUs and ~26% faster on 4; across
nodes the difference may be larger.

### Larger grid: 1024³ in Float32

Results on Nibi, Rorqual and Trillium, and what they show: [results/pressure_solver_1024.md](../results/pressure_solver_1024.md).

`jobs/submit_poisson_1024.sh` runs the solver alone on a 1024³ grid in Float32 (fits on one
H100-80GB, ~38 GiB) on 1, 2, 4 and 8 GPUs with MPI and NCCL (7 jobs; on Nibi all on one node). Motivation: GPU FFT libraries
scale better on larger grids (Verma et al. 2022, arXiv:2202.12756: 1024³ 2→4 GPUs ~90% vs ~77% at
512³). On rondeau, 512³ gave the same efficiencies as 512²×256 (1→2: 35%; 1→4: MPI 28%, NCCL 39%),
so our costs grow with the data; this checks it on H100 nodes.

## `alltoall_bandwidth.jl`

Times only the GPU-to-GPU `MPI_Alltoall` that each transpose of the distributed Poisson solvers
does (2 per pressure solve with an x-split, 3 solves per RK3 step), at the same sizes as
`nonhydrostatic_box.jl`. It prints the time per transpose and the bandwidth per GPU, and checks the data.

```bash
cd $OCEAN_HPC_ROOT
bash tools/run_local.sh --wait --gpus 2 --job-name a2a_2gpu_own benchmarks/alltoall_bandwidth.jl
bash tools/run_local.sh --wait --gpus 2 --all-visible --job-name a2a_2gpu_all benchmarks/alltoall_bandwidth.jl
grep -h "^RESULT" logs/a2a_*.out
```

**Result (pelee, 2 x A100-SXM4, Oct 13 2026):** 3.45 ms per transpose (268 MB sent per GPU,
~78 GB/s), identical with each rank seeing only its own GPU (`run_local.sh` default) and with
`--all-visible`. MPI therefore copies GPU-to-GPU over NVLink in both cases. Per RK3 step that is
~21 ms, about a third of the ~65 ms that 2 GPUs lose in `nonhydrostatic_box.jl`; the rest is
elsewhere (distributed FFT kernels, packing, or the rest of the model). Use this script to check
a new machine or MPI version.

# Oceananigans scaling on Nibi (October 2–14, 2026)

**Measured before the two GPU-to-GPU settings** of `docs/drac.md` step 7 (`--gpus-per-task` and the
CUDA.jl memory pool on). Kept as the record of those runs; the current numbers, on Nibi, Rorqual and
Trillium, are in [hydrostatic_scaling.md](hydrostatic_scaling.md).

## Setup

- **Benchmark:** Oceananigans benchmark suite, case `earth_ocean`, latitude–longitude grid
  1440 × 720 × 200 (207,360,000 cells), Float64, WENO vector-invariant momentum advection,
  WENO7 tracer advection, CATKE, 2 tracers, split Runge–Kutta 3, Δt = 60 s.
- **Timing:** 5 warm-up steps, then 5 windows of 100 steps; the time per step is the
  **fastest** window (as reported by the suite). "Spread" is how much slower the slowest
  window was.
- **Hardware:** Nibi GPU nodes, 8 × NVIDIA H100 80 GB HBM3 per node, Intel Xeon Platinum 8570.
- **Software:** Julia 1.10.10, Oceananigans 0.113.5, CUDA.jl 6.1.0, OpenMPI 4.1.5 (system).
- **Distribution:** one MPI rank per GPU, grid split in x only (`--partition=Nx1x1`).
- **Date:** 2026-10-02.

## Strong scaling (fixed size 1440 × 720 × 200)

| GPUs | Nodes | Cells per GPU | Time per step (s) | Speedup | Efficiency | Throughput (cells/s) | Spread |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 207,360,000 | 1.0110 | 1.00 | 100% | 2.05e8 | 0.1% |
| 2 | 1 | 103,680,000 | 0.5228 | 1.93 | 96.7% | 3.97e8 | 1.7% |
| 4 | 1 | 51,840,000 | 0.2594 | 3.90 | 97.4% | 7.99e8 | 1.2% |
| 8 | 1 | 25,920,000 | 0.1438 | 7.03 | 87.9% | 1.44e9 | 4.4% |
| 16 | 2 | 12,960,000 | 0.0851 | 11.87 | 74.2% | 2.44e9 | 23% |
| 32 | 4 | 6,480,000 | 0.0689 | 14.67 | 45.9% | 3.01e9 | 60% |

Throughput is for the whole grid (total cells / time per step), not per GPU.

**Reading the results.** Within one node (up to 8 GPUs) efficiency stays at 88–97%.
Across nodes it falls, because communication between nodes is slower and each GPU's
share becomes too small to keep an H100 busy (45 columns at 32 GPUs). The large spread at
16 and 32 GPUs means typical times there are noticeably slower than the fastest window.

## Weak scaling (about 207 million cells per GPU)

Each step doubles the resolution in both horizontal directions and multiplies the GPUs by 4, so
every GPU keeps the same 207 million cells (the 1-GPU grid). Grid split in x only.

| GPUs | Nodes | Grid (resolution) | Cells per GPU | Time per step (s) | Median (s) | Efficiency | GPU memory per rank |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1440 × 720 × 200 (1/4°) | 207,360,000 | 1.0110 | – | 100% | – |
| 4 | 1 | 2880 × 1440 × 200 (1/8°) | 207,360,000 | 1.0367 | 1.0368 | 97.5% | 47.7 GiB (247 B/cell) |
| 16 | 2 | 5760 × 2880 × 200 (1/16°) | 207,360,000 | to run | | | |
| 64 | 8 | 11520 × 5760 × 200 (1/32°) | 207,360,000 | 1.1929 | 1.1998 | 84.7% | 54.9 GiB (284 B/cell) |

Efficiency = time on 1 GPU / time on N GPUs (fastest windows). The 64-GPU run (job 23130970,
Oct 5, Δt = 7.5 s) is in `b32_gpu64_23130970.md`; its windows agree within 1%. The 4-GPU run
(job 23883358, Oct 14, Δt = 30 s): windows within 0.1%.

**Reading the results.** At a production-sized load per GPU, 64 GPUs on 8 nodes keep 85% of the
single-GPU speed: a 13-billion-cell 1/32° global grid runs at 1.2 s per step. This is the regime the
production runs will use (as many cells per GPU as fit), unlike the strong-scaling table, where at
32 GPUs each GPU has too little work. Memory: 55 GiB of 80 per GPU, so about 290 million cells per
H100 is the practical limit for this configuration.

`python3 tools/summarize_benchmarks.py <json files>` makes one table from the suite's JSON output
(fastest and median times, memory, strong and weak efficiency).

## Follow-up

The open items of this page (weak scaling at 16 and 64 GPUs, medians and memory for every run) were
rerun with the two settings: see [hydrostatic_scaling.md](hydrostatic_scaling.md).

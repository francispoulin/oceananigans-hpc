# Hydrostatic scaling on the Alliance clusters (October 2026)

The current numbers, measured with both GPU-to-GPU settings of `docs/drac.md` step 7
(`--gpus-per-node`, CUDA.jl memory pool off). The earlier Nibi runs (Oct 2–14, without them) are in
[nibi_scaling.md](nibi_scaling.md).

**Status (Oct 18): draft.** Trillium is complete; Nibi has 4, 8 and 32 GPUs (MPI); Rorqual's 16-GPU
runs and the rest of Nibi's are queued, and their rows say *pending*. Nibi's efficiencies wait for its
1-GPU run.

## Setup

- **Benchmark:** Oceananigans benchmark suite, case `earth_ocean`: latitude–longitude grid, 200
  levels, Float64, WENO vector-invariant momentum, WENO7 tracers, CATKE, 2 tracers, split Runge–Kutta 3.
  Suite at Oceananigans commit 8743c40d0 (`setup/setup_benchmark_suite.sh`, the same on every cluster).
- **Timing:** 5 warm-up steps, then 5 windows of 100 steps. "Fastest" is the fastest window (what
  the suite reports), "median" the median window; efficiencies use the fastest window.
- **Distribution:** one MPI rank per GPU, grid split in x; MPI (CUDA-aware OpenMPI 4.1.5) or NCCL
  (`COMM=NCCL`).
- **Software:** Julia 1.10.10, Oceananigans 0.113.5, CUDA.jl 6.4.1 (oceananigans-hpc v0.1.0 settings).
- **Hardware:** H100 80 GB. Nibi: 8 per node (NVSwitch); Rorqual: 4 per node, one InfiniBand card
  per node; Trillium: 4 per node, six InfiniBand cards per node.
- **Reproduce:** `bash jobs/submit_hydro_nccl.sh` (1 GPU, then 1, 2 and 4 full nodes, MPI and NCCL),
  then `python3 tools/summarize_benchmarks.py $BENCH_DIR/results/hyd*.json`.

## Strong scaling, 1/4° (1440 × 720 × 200, 207 million cells)

Time per step in seconds (fastest window); efficiency = time on 1 GPU / (N × time on N GPUs).

| GPUs | Trillium nodes | Trillium MPI | Trillium NCCL | Rorqual nodes | Rorqual MPI | Rorqual NCCL | Nibi nodes | Nibi MPI | Nibi NCCL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1.0461 | – | 1 | 1.051 | – | 1 | pending | – |
| 2 | | | | | | | 1 | pending | |
| 4 | 1 | 0.2638 (99%) | 0.2622 (100%) | 1 | 0.264 (100%) | 0.263 (100%) | 1 | 0.2633 | |
| 8 | 2 | 0.1429 (91%) | 0.1413 (93%) | 2 | 0.148 (88%) | 0.142 (93%) | 1 | 0.1419 | pending |
| 16 | 4 | 0.0819 (80%) | 0.0791 (83%) | 4 | pending | pending | 2 | pending | pending |
| 32 | | | | | | | 4 | 0.0550 | pending |

GPU memory per rank on Trillium: 46.6 GiB on 1 GPU, 13.5–14.4 on 4, 7.8–8.2 on 8, 4.9–5.4 on 16
(NCCL uses 0.4–0.9 GiB more than MPI). Median windows are within 0.4% of the fastest on Trillium.

For comparison, Nibi before the two settings (Oct 2, [nibi_scaling.md](nibi_scaling.md)): 1 GPU
1.0110 s, then 97%, 97%, 88%, 74% and 46% at 2, 4, 8, 16 and 32 GPUs.

**Nibi, same GPU counts, before and after the two settings** (s per step, fastest window; slowest
window in brackets, as a percentage above the fastest):

| GPUs | Nodes | Oct 2 | Oct 18 | Change |
| --- | --- | --- | --- | --- |
| 4 | 1 | 0.2594 (+1%) | 0.2633 (+2%) | 1.5% slower |
| 8 | 1 | 0.1438 (+4%) | 0.1419 (+2%) | 1% faster |
| 32 | 4 | 0.0689 (+60%) | 0.0550 (+25%) | 20% faster |

Within a node the settings change almost nothing for the hydrostatic model (it exchanges only
halos; the 1.5% is the cost of the memory pool being off, also seen on one GPU). Across 4 nodes it
is 20% faster and much steadier; against the Oct 2 single-GPU time, efficiency at 32 GPUs goes from
46% to about 57%. GPU memory per rank: 13.5, 7.8 and 3.5 GiB at 4, 8 and 32 GPUs.

**Reading the results (so far).** Within a node the hydrostatic model scales perfectly (99–100% on
4 GPUs). Across nodes it keeps 88–93% on 2 nodes and 80–83% on 4, although at 16 GPUs each GPU
has only 13 million cells: the model exchanges only thin halos, so the network matters much less than
for the nonhydrostatic pressure solve ([pressure_solver_1024.md](pressure_solver_1024.md)). NCCL
gains 1–4% once the run crosses nodes and is the same as MPI within a node.

## Weak scaling on Nibi (about 207 million cells per GPU)

Each step doubles the resolution in both horizontal directions and multiplies the GPUs by 4; the
time step halves with the grid spacing. Grid split in x, except where noted.

| GPUs | Nodes | Grid (resolution) | Δt (s) | Time per step (s) | Efficiency | Job |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1440 × 720 × 200 (1/4°) | 60 | pending | 100% | `hyd2_1gpu` |
| 4 | 1 | 2880 × 1440 × 200 (1/8°) | 30 | pending | | `wk_4gpu` |
| 16 | 2 | 5760 × 2880 × 200 (1/16°) | 15 | pending | | `wk_16gpu` |
| 64 | 8 | 11520 × 5760 × 200 (1/32°) | 7.5 | pending | | `wk_64gpu` |
| 64 | 8 | 11520 × 5760 × 200, 8 × 8 split | 7.5 | pending | | `wk_64gpu_8x8` |

Before the two settings (Oct 5–14): 97.5% on 4 GPUs and 84.7% on 64 GPUs (1.1929 s per step;
54.9 GiB per GPU, so about 290 million cells per H100 is the practical limit).

## Notes

- Efficiency on Trillium and Rorqual is against their own 1-GPU time (1.046 and 1.051 s), about
  3.5% slower than Nibi's Oct 2 run (1.011 s); the memory pool being off is the likely reason.
- Rorqual's numbers are from Oct 16, Trillium's from Oct 17; the software versions on each
  cluster are in [tests/](tests/).

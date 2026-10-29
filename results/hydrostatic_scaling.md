# Hydrostatic scaling on the Alliance clusters (October 2026)

The current numbers, measured with both GPU-to-GPU settings of `docs/drac.md` step 7
(`--gpus-per-node`, CUDA.jl memory pool off). The earlier Nibi runs (Oct 2–14, without them) are in
[nibi_scaling.md](nibi_scaling.md).

**Status (Oct 27): complete.** Trillium and Rorqual up to 16 GPUs; Nibi: strong scaling on 1–32 GPUs
with MPI, and with NCCL on 8–32 (16 GPUs: job 24167390, Oct 24); weak scaling on 1–64 GPUs, on 64 also
with a 2-D split. Rorqual also at 1/8° on 4–16 GPUs.

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

![Time per step and strong-scaling efficiency against GPUs, Nibi, Trillium and Rorqual, MPI and NCCL, with Nibi before the GPU settings](hydrostatic_scaling.png)

Time per step in seconds (fastest window); efficiency = time on 1 GPU / (N × time on N GPUs).
The figure is made from this table: `python3 tools/plot_scaling.py` (after editing the table).

| GPUs | Trillium nodes | Trillium MPI | Trillium NCCL | Rorqual nodes | Rorqual MPI | Rorqual NCCL | Nibi nodes | Nibi MPI | Nibi NCCL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1.0461 | – | 1 | 1.051 | – | 1 | 1.0459 | – |
| 2 | | | | | | | 1 | 0.5352 (98%) | |
| 4 | 1 | 0.2638 (99%) | 0.2622 (100%) | 1 | 0.264 (100%) | 0.263 (100%) | 1 | 0.2633 (99%) | |
| 8 | 2 | 0.1429 (91%) | 0.1413 (93%) | 2 | 0.148 (88%) | 0.142 (93%) | 1 | 0.1419 (92%) | 0.1404 (93%) |
| 16 | 4 | 0.0819 (80%) | 0.0791 (83%) | 4 | 0.0866 (76%) | 0.0797 (82%) | 2 | 0.0805 (81%) | 0.0785 (83%) |
| 32 | | | | | | | 4 | 0.0550 (59%) | 0.0511 (64%) |

GPU memory per rank on Trillium: 46.6 GiB on 1 GPU, 13.5–14.4 on 4, 7.8–8.2 on 8, 4.9–5.4 on 16
(NCCL uses 0.4–0.9 GiB more than MPI); the same on Rorqual and Nibi. Median windows are within 0.4% of
the fastest on Trillium and Rorqual, and on Nibi up to 8 GPUs; on Nibi at 16 and 32 GPUs the median is
3% and 1% above the fastest, and the slowest window 8% and 25%.

For comparison, Nibi before the two settings (Oct 2, [nibi_scaling.md](nibi_scaling.md)): 1 GPU
1.0110 s, then 97%, 97%, 88%, 74% and 46% at 2, 4, 8, 16 and 32 GPUs.

**Nibi before and after the two settings** (s per step, fastest window; slowest window in brackets,
as a percentage above the fastest; efficiency against the 1-GPU run of the same day):

| GPUs | Nodes | Oct 2 | Oct 17–20 | Change | Efficiency Oct 2 → Oct 17–20 |
| --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1.0110 (+0%) | 1.0459 (+0%) | 3.5% slower | – |
| 2 | 1 | 0.5228 (+2%) | 0.5352 (+0%) | 2.4% slower | 97% → 98% |
| 4 | 1 | 0.2594 (+1%) | 0.2633 (+2%) | 1.5% slower | 97% → 99% |
| 8 | 1 | 0.1438 (+4%) | 0.1419 (+2%) | 1% faster | 88% → 92% |
| 16 | 2 | 0.0851 (+23%) | 0.0805 (+8%) | 5% faster | 74% → 81% |
| 32 | 4 | 0.0689 (+60%) | 0.0550 (+25%) | 20% faster | 46% → 59% |

Within a node the settings change almost nothing for the hydrostatic model (it exchanges only
halos): 1–4 GPUs are 1.5–3.5% slower, the cost of the memory pool being off, which is also seen on one
GPU. Across nodes runs are faster and much steadier: 5% faster on 2 nodes and 20% on 4, with the
spread between windows down from 23% to 8% and from 60% to 25%. GPU memory per rank: 46.6, 24.8, 13.5,
7.8, 4.9 and 3.5 GiB on 1 to 32 GPUs.

**Reading the results (so far).** Within a node the hydrostatic model scales almost perfectly (98–100%
on 2 and 4 GPUs, 92% on Nibi's 8). Across nodes it keeps 88–93% on 2 four-GPU nodes and 76–83% at
16 GPUs on every cluster, although each GPU then has only 13 million cells; at 32 GPUs (Nibi, 6.5 million
cells per GPU) it falls to 59%: the model exchanges only thin halos, so the network matters much less than
for the nonhydrostatic pressure solve ([pressure_solver_1024.md](pressure_solver_1024.md)). NCCL
gains 1–4% on 2 nodes and is the same as MPI within a node; on 4 Nibi nodes (32 GPUs, one run, Oct 27)
it is 7% faster (64% against 59%) and steadier (slowest window 13% above the fastest, against 25%), with
4.0 GiB per rank against 3.5.

## Strong scaling at 1/8° on Rorqual (2880 × 1440 × 200, 829 million cells)

The grid is too large for one GPU, so efficiency is against 4 GPUs on one node:
efficiency = 4 × time on 4 GPUs / (N × time on N GPUs). Δt = 30 s. Jobs `b8_{MPI,NCCL}_{4,8,16}gpu`,
Oct 21–23 (`--cpus-per-task=8`, both GPU settings).

| GPUs | Nodes | Cells per GPU | MPI (s/step) | NCCL (s/step) | GPU memory per rank (GiB) |
| --- | --- | --- | --- | --- | --- |
| 4 | 1 | 207 M | 1.0683 | 1.0685 | 48–49 |
| 8 | 2 | 104 M | 0.5417 (99%) | 0.5414 (99%) | 26 |
| 16 | 4 | 52 M | 0.2845 (94%) | 0.2849 (94%) | 15 |

With 4 times the cells per GPU of the 1/4° grid, crossing nodes costs little: 94% on 4 nodes, against
76% (MPI) and 82% (NCCL) for 1/4° on the same 16 GPUs. MPI and NCCL are the same.

## Weak scaling on Nibi (about 207 million cells per GPU)

Each step doubles the resolution in both horizontal directions and multiplies the GPUs by 4; the
time step halves with the grid spacing. Grid split in x, except where noted.

| GPUs | Nodes | Grid (resolution) | Δt (s) | Time per step (s) | Efficiency | Job |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1440 × 720 × 200 (1/4°) | 60 | 1.0459 | 100% | `hyd2_1gpu` |
| 4 | 1 | 2880 × 1440 × 200 (1/8°) | 30 | 1.0683 | 98% | `wk_4gpu` |
| 16 | 2 | 5760 × 2880 × 200 (1/16°) | 15 | 1.0812 | 97% | `wk_16gpu` |
| 64 | 8 | 11520 × 5760 × 200 (1/32°) | 7.5 | 1.2078 | 87% | `wk_64gpu` |
| 64 | 8 | 11520 × 5760 × 200, **8 × 8 split** | 7.5 | **1.0665** | **98%** | `wk_64gpu_8x8` |

GPU memory per rank: 46.6 GiB on 1 GPU, 48.4 on 4; on 64, 55.7 GiB split in x and 48.6 with the 8 × 8
split. Windows on 64 GPUs: median 0.8% (x) and 0.2% (8 × 8) above the fastest, slowest 1.4% and 2.0%.
Before the two settings (Oct 5–14): 97.5% on 4 GPUs and 84.7% on 64 GPUs split in x (1.1929 s per step,
against a 1-GPU run of 1.011 s; 54.9 GiB per GPU).

**Reading the results.** At a production-sized load per GPU the model keeps 97–98% up to 16 GPUs on 2
nodes. On 64 GPUs on 8 nodes, **how the grid is split matters more than the number of nodes**:

- **Split in x (64 × 1):** each rank holds a strip of 180 × 5760 columns and exchanges halos along its
  two long sides (2 × 5760 columns). 87%, about what it was before the GPU settings (85%): at over a
  second of work per step, communication is a small part, so the settings change little here.
- **Split in both directions (8 × 8):** each rank holds a 1440 × 720 tile, the same shape as the 1-GPU
  problem, whose edges add up to 2 × (1440 + 720) = 4320 columns, about 2.7 times less halo to exchange.
  **98% on 8 nodes**: 12% faster than the strips, and 7 GiB less memory per GPU, since a strip carries
  proportionally more halo cells.

So for production runs across many nodes, split the grid in both directions (`PARTITION=8x8x1` for
`jobs/benchmark.sh`; in a simulation, `Partition(x = 8, y = 8)`): a 13-billion-cell 1/32° global grid
then runs at 1.07 s per step on 64 GPUs, with room left for more cells per GPU. These are single runs,
but their windows agree within 2%. Each 64-GPU job took 17–20 minutes (about 10 of them stepping).

## Notes

- Efficiency on each cluster is against its own 1-GPU time with the same settings: 1.046 s on Trillium and
  Nibi, 1.051 s on Rorqual; all about 3.5% slower than Nibi's Oct 2 run (1.011 s), the memory pool being off.
- Efficiencies here use the fastest window; `tools/summarize_benchmarks.py` reports them from the median,
  which differs by at most 2 points (Nibi, 16 GPUs).
- Rorqual's numbers are from Oct 15–18, Trillium's from Oct 17, Nibi's from Oct 17–20 (jobs 24350485–90 and
  24042817–18) and Oct 27 (NCCL on 32 GPUs, 25116374; weak scaling on 64, 24168416–17, nodes
  g[13-15,19-22,29]); the software versions on each
  cluster are in [tests/](tests/).

# The nonhydrostatic pressure solve on the Alliance clusters (October 2026)

The pressure solve is the part of a nonhydrostatic model that needs all-to-all communication: each
solve transposes the full 3-D field between GPUs. This page times it alone
(`benchmarks/poisson_solver.jl`), with MPI and with NCCL, after the two GPU-to-GPU settings of
`docs/drac.md` step 7.

**Status (Oct 22): complete** for 1–8 GPUs on Nibi, Trillium and Rorqual.

## Setup

- **Solver:** Fourier-tridiagonal (FFTs in x and y, tridiagonal in z), built as
  `NonhydrostaticModel` builds it; time per solve includes the source term.
- **Timing:** 20 solves per window, 5 windows; the fastest window is reported, with the time spent
  in the two transposes in brackets.
- **Check:** `p_std` (pressure variation about its mean) is the same on every GPU count and with MPI
  and NCCL, to round-off, on every cluster.
- **Software:** Julia 1.10.10, Oceananigans 0.113.5, CUDA.jl 6.4.1, `envs/nccl` (NCCL.jl added).
- **Reproduce:** `bash jobs/submit_poisson_1024.sh` (7 jobs: 1 GPU, then 2, 4 and 8 with MPI and with
  NCCL), then `grep -ah "^RESULT poisson" logs/p1024_*.out`.

## 1024³ in Float32: ms per solve (transposes)

| GPUs | Nibi MPI | Nibi NCCL | Trillium MPI | Trillium NCCL | Rorqual MPI | Rorqual NCCL |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 78.5 | – | 78.3 | – | 79.0 | – |
| 2 | 143.7 (34.6) | 141.2 (34.4) | 163.9 (56.9) | 163.6 (57.1) | 164.1 (57.0) | 166.6 (57.4) |
| 4 | 77.6 (25.0) | 72.2 (19.5) | 71.8 (19.0) | 74.0 (21.3) | 71.7 (19.0) | 74.2 (21.4) |
| 8 | 43.3 (16.5), 1 node | 37.1 (10.5), 1 node | 179.7 (164.5), 2 nodes | 83.1 (55.9), 2 nodes | 336.0 (313.0), 2 nodes | 206–246 (180–225), 2 nodes |

Efficiency from 2 to 4 GPUs: Nibi 93% (MPI) and 98% (NCCL); Trillium and Rorqual 110–114%. From 4 to
8 GPUs within one Nibi node (NVSwitch): 90% with MPI (43.3 ms, transposes 16.5 ms) and 97% with NCCL
(37.1 ms, transposes 10.5 ms), the fastest solve measured; across two nodes
on Trillium and Rorqual the solve is 1.1 to 4.7 times slower than on 4 GPUs. GPU
memory per GPU (MPI): 41.0 GiB on 1 GPU, 37.5 on 2, 19.4 on 4, 10.4 on 8; NCCL needs 0.6–2.7 GiB more.

Before the two settings, the same solve on Nibi took 445 ms on 2 GPUs and 700 ms on 4 (transposes
344 ms on 2 GPUs): slower than one GPU. The settings made it 3 and 9 times faster.

## 512 × 512 × 256 in Float64, Fir: ms per solve (transposes)

| Case | GPUs | Nodes | MPI | NCCL |
| --- | --- | --- | --- | --- |
| Strong (512 × 512 × 256) | 4 | 1 | 6.69 (2.13) | 6.73 (2.19) |
| | 8 | 2 | 20.9 (18.9) | pending |
| Weak (512 × 512 × 256 per GPU) | 4 | 1 | 26.9 (8.2) | 27.9 (9.3) |
| | 8 | 2 | 155 (141) | pending |

From `jobs/submit_poisson_scaling.sh`, Oct 17; the 1- and 2-GPU runs and the NCCL runs on 8 GPUs are
still queued.

## What the numbers show

1. **Within a node, communication is no longer the problem.** With both settings MPI matches NCCL,
   and the transposes take 19–35 ms of a 72–144 ms solve.
2. **The 1 → 2 GPU step costs the most** (efficiency 24–28%): the distributed solve replaces the
   single-GPU transform with 1-D FFTs, permutations and packing, and that local work on half the
   grid (~108 ms) takes longer than the whole solve on one GPU (78.5 ms). Local work at 4 GPUs is
   the same on all clusters (~53 ms). Reducing the permutations is the main lever (`ROADMAP.md`,
   *Later*).
3. **On Trillium and Rorqual 2 GPUs are slower than on Nibi** (57 vs 35 ms of transposes): a pair of
   GPUs there shares 6 of 18 NVLinks (no NVSwitch). At 4 GPUs all links are used and all clusters match.
4. **Across nodes the network sets the limit.** On 8 GPUs over 2 nodes the solve is slower than on
   4 GPUs in one node on every cluster. At 1024³, with NCCL: 1.1 times slower on Trillium and 2.8–3.3
   times on Rorqual; with MPI: 2.5 and 4.7 times. On Fir (512²×256, MPI): 3 times. Rorqual's GPU nodes
   have one InfiniBand card each (NCCL already uses it with GPUDirect RDMA), Trillium's six. Across
   nodes NCCL is 1.4–2.2 times faster than MPI.

**Rule:** keep the nonhydrostatic pressure solve within one node (up to 8 GPUs on Nibi, 4 elsewhere),
and use NCCL when it must cross nodes. The hydrostatic model, which exchanges only halos, scales
well across nodes ([hydrostatic_scaling.md](hydrostatic_scaling.md)).

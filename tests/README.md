# Platform tests

One command per machine checks that the platform works: environment, packages, grids, the
hydrostatic and nonhydrostatic models on 1, 2 and 4 GPUs, multi-GPU communication, checkpoints, file
output, and plotting. Run them after setting up a machine, and **before adopting any library update**
(Oceananigans, CUDA, MPI, a new module). They prove that things work; they do not measure
performance (that is `benchmarks/`).

```bash
ocean_setup
bash $OCEAN_HPC_ROOT/tools/run_tests.sh                 # 1 and 4 GPUs (~10 min)
bash $OCEAN_HPC_ROOT/tools/run_tests.sh --gpus "1 2"     # if only 2 GPUs are free
bash $OCEAN_HPC_ROOT/tools/run_tests.sh --gpus "1 2 4"   # everything (~16 min)
```

All platform tests for one GPU count run in **one Julia process** (`tests/platform.jl`): packages are
loaded and kernels compiled once, which is most of the time (the models are tiny; each new model type
costs a one-time compile of 25-50 s, about twice that on several GPUs). 4 GPUs cover everything 2 GPUs
do, so 2 is not run by default. The 1-GPU run saves reference fields;
the 2- and 4-GPU runs compare their part with them (so run 1 GPU first; otherwise the comparisons
are SKIPPED).

- **pelee / rondeau:** one step after another through `tools/run_local.sh`. A step that needs more
  GPUs than are free is marked SKIP, not FAIL.
- **Alliance:** submits one Slurm job with all steps (1 node, as many GPUs as the largest step).

The summary goes to `results/tests/<machine>_<date-time>.md`: commit it, it is the record of what
was tested and with which versions. One log per step in `logs/`.

## What is tested

| Test | GPUs | What it shows |
| --- | --- | --- |
| `check_env` | – | environment and this repository's project (warnings, not failures) |
| `load` | 1, 4 (2) | packages load (versions recorded), GPU works, MPI starts |
| `grids` | 1 | uniform, z-stretched, latitude-longitude and immersed grids on the GPU; fields, ∂x |
| `single_mpi` | 1, 4 (2) | one MPI only, the system OpenMPI (with NetCDF loaded) |
| `cuda_aware` | 4 (2) | one GPU per rank; GPU arrays pass through MPI |
| `halo` | 4 (2) | halo exchange: distributed ∂x equals the single-GPU result |
| `output` | 1, 4 (2) | NetCDF and JLD2 written and read back under MPI |
| `hydro_channel` | 1, 4 (2) | hydrostatic, periodic x / walls y (jet-like), WENO, split-explicit free surface, RK3: 30 steps; 4 (2) GPUs match 1 GPU |
| `hydro_box` | 1, 4 (2) | hydrostatic, bounded x, y, z (vortex-like): 30 steps; 4 (2) GPUs match 1 GPU |
| `checkpoint` | 1, 4 (2) | 20 straight steps = 10 steps, checkpoint, restart, 10 steps (bitwise expected) |
| `nh_fft` | 1, 4 (2) | nonhydrostatic, FFT pressure solver: 10 steps; 4 (2) GPUs match 1 GPU |
| `nh_ft` | 1, 4 (2) | nonhydrostatic, stretched z, Fourier-tridiagonal solver: 10 steps; 4 (2) GPUs match 1 GPU |
| `viz` | CPU | viz environment: NetCDF read, PNG and MP4 with CairoMakie |

"Match": relative difference below 1e-8. (2) = only with `--gpus "1 2 ..."`. The hydrostatic grids
have 128 cells in x (32 per rank on 4 GPUs), more than the split-explicit free surface's 16-cell halo.

First full run, rondeau, Oct 13: all 31 passed; hydrostatic 2 and 4 GPUs bitwise equal to 1 GPU,
checkpoint/restart bitwise, nonhydrostatic ~5e-14 (summation order in the distributed FFT).

Since Oceananigans 0.116.1 (Oct 26) the hydrostatic tests agree to round-off (~1e-14) instead of
bitwise: the split-explicit free surface and the halo exchange were rewritten after 0.113.5. Over
3000 steps the 4- (and 2-) GPU difference grows no faster than a one-rounding-unit change of the
initial state does on 1 GPU, so it is round-off carried by the flow (`benchmarks/hydro_box_drift.jl`
on the library-upgrade branch). Checkpoint/restart stays bitwise.

## Scope

These tests check the **platform**: environment, MPI, CUDA, Oceananigans and the other libraries,
and `viz`. They never depend on a simulation repository. Simulation physics and regressions
(e.g. BalancedFlows' vortex and jet gates) are tested in those repositories, which may run
`check_env` first and assume the platform works.

## To add (the list grows as needed)

- Performance: the hydrostatic and nonhydrostatic benchmarks within a few % of stored numbers.
- NumericalEarth / ClimaSeaIce load and a short coupled run (library-level, a generic box).
- Across nodes (Alliance): the multi-GPU tests on 2 nodes.
- A time limit per step, so a hung MPI test cannot block the run.

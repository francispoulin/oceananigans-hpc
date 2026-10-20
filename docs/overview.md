# How oceananigans-hpc fits together

Start here. This page explains the structure; the details are in the pages it links to.

## What the repository is

One **tested environment** for running Oceananigans on every machine the group uses, and the
**shared tools** around it. Simulation code lives in its own repositories (one per project) and
relies on this one by convention: it is not a Julia package and is never listed as a dependency.

| Machines | Scheduler | Environment file | Guide |
| --- | --- | --- | --- |
| Alliance: Nibi, Fir, Rorqual, Trillium (H100) | Slurm | `env/drac.sh` | [drac.md](drac.md) |
| Waterloo fluids group: pelee, rondeau (A100, shared drive) | none | `env/fluidsgpu.sh` | [fluidsgpu.md](fluidsgpu.md) |

## The pieces

```
              ~/.bashrc:  alias ocean_setup='source .../env/ocean_setup.sh'
                                         |
                       env/ocean_setup.sh  (detects the machine)
                          /                         \
                 env/drac.sh                   env/fluidsgpu.sh
                          \                         /
     modules (Julia, system OpenMPI, CUDA), one Julia depot, MPI variables, thread limits
                                         |
       ------------------------------------------------------------------------
       |                         |                                          |
  this repository's         viz/                                   your project's
  environment (tested)      plotting environment                   environment
  Oceananigans, CUDA, MPI,  CairoMakie + NCDatasets only,          (e.g. BeaufortGyre):
  NCDatasets, JLD2:         no Oceananigans, no MPI:               simulation packages,
  checks, tests,            movies and plots of NetCDF             never Makie;
  benchmarks                output                                 LocalPreferences.toml
                                                                   from configure_mpi.sh
```

**Three kinds of Julia environment, kept separate on purpose:**

1. **This repository's** (`Project.toml` + `Manifest.toml` at the root): the exact versions that
   were tested. Used by the checks, the tests and the benchmarks.
2. **`viz/`**: plotting only. Simulations never load Makie, and Makie's version limits never hold
   back Oceananigans or CUDA. Plotting scripts read NetCDF output directly.
3. **Each simulation project's own**: its own versions, plus a machine-specific
   `LocalPreferences.toml` (not committed) that points MPI at the system OpenMPI.

All three share **one depot per machine** (`JULIA_DEPOT_PATH`), so packages are downloaded and
compiled once. The **global environment** (`@v1.10`) stays **empty**: anything in it is visible to
every project and hides missing dependencies.

**What every environment file provides** (so scripts work on any machine): `OCEAN_HPC_ROOT`,
`OCEAN_MACHINE`, `OCEAN_MPI_ROOT`, `OPAL_PREFIX`, `JULIA_DEPOT_PATH`, `JULIA_NUM_THREADS`,
`JULIA_NUM_PRECOMPILE_TASKS`, and `julia` and `mpiexec` on PATH. Details: [env/README.md](../env/README.md).

## Everyday use

```bash
ocean_setup                                   # every new terminal, on every machine
check_env                                     # if anything seems wrong (alias for tools/check_env.sh)
```

| Task | Alliance | pelee / rondeau |
| --- | --- | --- |
| Run a simulation | your project's Slurm script (sources `env/ocean_setup.sh`) | `tools/run_local.sh --gpus 4 scripts/run.jl ...` |
| Make movies / plots | `sbatch $OCEAN_HPC_ROOT/jobs/viz.sh "scripts/make_movies.jl <run>"` | `tools/run_local.sh --gpus 0 --viz scripts/make_movies.jl <run>` |
| Check the whole setup | `tools/run_tests.sh` (submits one job) | `tools/run_tests.sh` |
| Benchmark | `jobs/benchmark.sh`, `jobs/benchmark_nh.sh` | `tools/run_local.sh ... benchmarks/nonhydrostatic_box.jl` |

`tools/run_local.sh` picks free GPUs (one per MPI rank), survives logout and writes a log, as
`sbatch` does on the Alliance.

## Setting things up

**A new machine of a known kind** (once): clone this repository; add the `ocean_setup` and
`check_env` aliases to `~/.bashrc`; then `bash setup/setup.sh` (this environment and system MPI),
`bash setup/setup_viz.sh`, and `bash tools/run_tests.sh`. Commit the test summary.

**A new simulation project** (once per machine): `bash $OCEAN_HPC_ROOT/setup/configure_mpi.sh
/path/to/project`; keep `Project.toml` at the project root; add `LocalPreferences.toml` to its
`.gitignore`; put a "Requirements: oceananigans-hpc" section in its README.

**A new kind of machine:** write `env/<machine>.sh` providing the variables above (copy
`fluidsgpu.sh` for a machine without Slurm), add a case to `env/ocean_setup.sh`, then follow "a new
machine".

## How a simulation project uses this repository

1. `ocean_setup` provides the shell environment (modules, depot, MPI variables).
2. The shared depot provides the packages (the project's own versions).
3. `configure_mpi.sh` wrote the project's `LocalPreferences.toml` (system OpenMPI).
4. Multi-GPU scripts load `src/drac_mpi.jl` through `ENV["OCEAN_HPC_ROOT"]` and call
   `drac_mpi_init()` after all `using` lines.
5. Plotting runs with `--project=$OCEAN_HPC_ROOT/viz`, so **plotting code must not load
   Oceananigans** (e.g. define `const days = 86400.0` rather than `using Oceananigans.Units`).

## Testing and updates

`tools/run_tests.sh` runs the platform tests ([tests/README.md](../tests/README.md)): packages and
versions, grids, hydrostatic (channel and fully bounded box) and nonhydrostatic models on 1, 2 and
4 GPUs (distributed results compared with one GPU), checkpoint/restart, MPI, file output, and `viz`.
They test the platform only; simulation repositories test their own physics. The summary goes to `results/tests/`.

Before adopting any library update (Oceananigans, CUDA, MPI, modules): try it in a separate
environment, run the tests and benchmarks, compare with the stored summaries, then update the
Manifest and re-run the tests on every machine.

## Rules learned the hard way

- Run `julia --project=.` only in a folder that has a `Project.toml` (otherwise Julia silently
  creates a new, empty project there).
- Install and precompile on a login node (internet), with `JULIA_NUM_PRECOMPILE_TASKS=2`
  (set by the environment files): more crashes login nodes.
- Never commit `LocalPreferences.toml`; always commit `Project.toml` and `Manifest.toml`.
- `git pull` before changing this repository, on every machine that has a clone.
- Credentials (e.g. ECCO) go in `~/.netrc` with `chmod 600`, never in shell files.

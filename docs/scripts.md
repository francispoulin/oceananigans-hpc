# Scripts: what each one is for

Every script in this repository, grouped by what you are trying to do: one line on what it does,
where to run it, and one example. **The full usage is in each script's header:** print it with
`-h` (for example `bash jobs/submit_gpu.sh -h`), wherever you are. The walkthroughs that use the
scripts in order are [drac.md](drac.md) (Alliance clusters), [fluidsgpu.md](fluidsgpu.md)
(pelee/rondeau) and [overview.md](overview.md) (how the pieces fit together). For your own
simulation repository: [simulation_repos.md](simulation_repos.md).

Where to run: **login** = an Alliance login node (internet, no GPUs); **job** = submitted with
`sbatch` (or `jobs/submit_gpu.sh`), never run directly; **server** = pelee or rondeau; **any** =
anywhere with bash after `ocean_setup`.

## Every session

| Script | What it does | Where | Example |
| --- | --- | --- | --- |
| `env/ocean_setup.sh` | Loads modules, sets the Julia depot and MPI for this machine; exports `OCEAN_HPC_ROOT` | any (source it) | `source env/ocean_setup.sh` (or the `ocean_setup` alias) |
| `tools/check_env.sh` | Checks the environment and a project folder, and says what looks wrong | any | `bash $OCEAN_HPC_ROOT/tools/check_env.sh` |

`env/ocean_setup.sh` picks one of `env/drac.sh` (Alliance) or `env/fluidsgpu.sh` (pelee/rondeau);
those two are not run or sourced directly. [env/README.md](../env/README.md) lists the variables
they export.

## Setting up a machine (once)

| Script | What it does | Where | Example |
| --- | --- | --- | --- |
| `setup/install_julia.sh` | Installs the official Julia release the platform's Manifest was made with, where the modules lack it (pelee/rondeau; once per version) | server | `bash setup/install_julia.sh` |
| `setup/setup.sh` | Installs the packages and points MPI.jl and OpenMPI_jll at the system MPI | login, server | `bash setup/setup.sh` |
| `setup/setup_viz.sh` | Sets up `viz/`, the plotting environment (CairoMakie, NCDatasets) | login, server | `bash setup/setup_viz.sh` |
| `setup/configure_mpi.sh` | The MPI part of the setup, for your own project folder | login, server | `bash setup/configure_mpi.sh /path/to/project` |
| `setup/setup_nccl_env.sh` | A separate environment `envs/nccl` with NCCL.jl, for MPI vs NCCL runs | login, server | `bash setup/setup_nccl_env.sh` |
| `setup/setup_benchmark_suite.sh` | Checks out Oceananigans' benchmark suite (pinned commit) with the fixes these benchmarks need | login | `bash setup/setup_benchmark_suite.sh` |

## Testing the platform

| Script | What it does | Where | Example |
| --- | --- | --- | --- |
| `tools/test_branch.sh` | The platform tests of a branch, in a worktree next to the clone (which stays on `main`); publishes the summary | login, server | `bash tools/test_branch.sh claude/some-change` |
| `tools/publish_summary.sh` | Pushes one test summary as a `results/<machine>_<date>` branch, without touching the clone | login, server | `bash tools/publish_summary.sh --latest` |
| `tools/ci_platform_tests.sh` | The platform tests of one commit, run by the Buildkite agent on pelee/rondeau ([ci.md](ci.md)); waits for free GPUs, shows the summary on the build page | server | `bash tools/ci_platform_tests.sh <commit>` |
| `tools/run_tests.sh` | The platform tests (21 on 1 and 4 GPUs, ~10 min); submits one job on the Alliance, runs directly on pelee/rondeau; writes `results/tests/<machine>_<date>.md` | login, server | `bash tools/run_tests.sh` |
| `jobs/checks.sh` | Four multi-GPU checks (one MPI, CUDA-aware MPI, distributed vs one GPU, output) on any number of GPUs | job | `bash jobs/submit_gpu.sh jobs/checks.sh 16` |
| `jobs/hello_cpu.sh`, `jobs/hello_gpu.sh` | A first Oceananigans run on a CPU node and on one GPU | job | `sbatch jobs/hello_gpu.sh` |
| `tests/ci/run_all.sh` | The checks GitHub runs on every pull request (no GPUs or Slurm needed) | any | `bash tests/ci/run_all.sh` |
| `tests/ci/test_branch_tools.sh` | Part of `run_all.sh`: `test_branch.sh` and `publish_summary.sh` against a throwaway local repository | any | `bash tests/ci/test_branch_tools.sh` |
| `tests/ci/test_submit_scripts.sh` | Part of `run_all.sh`: the Slurm options of the submit scripts on each cluster | any | `bash tests/ci/test_submit_scripts.sh` |

`tests/ci/` also holds `check_links.py`, `check_cluster_facts.py`, `check_scripts_documented.py` and
`check_julia_version.py` (run by `run_all.sh`).
What the tests cover: [tests/README.md](../tests/README.md).

## Running jobs

| Script | What it does | Where | Example |
| --- | --- | --- | --- |
| `jobs/submit_gpu.sh` | Submits a GPU job script, this repository's or another's, on N GPUs with the right Slurm options for the cluster; options after `--` go to the script (`DRYRUN=1` prints the command) | login | `bash jobs/submit_gpu.sh jobs/checks.sh 8` |
| `jobs/viz.sh` | A plotting job on a CPU node, with the `viz` environment, from your project folder | job | `sbatch $OCEAN_HPC_ROOT/jobs/viz.sh scripts/make_movies.jl` |
| `tools/run_local.sh` | The same as a job, on pelee/rondeau (no Slurm): picks free GPUs, runs in the background, writes a log | server | `bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpus 4 scripts/run.jl` |

`jobs/gpu_request.sh` holds the Slurm rules of each cluster (GPUs per node, memory, Trillium's
"1 GPU or whole nodes"); the submit scripts and `run_tests.sh` source it. It is not run on its own.

## Benchmarks

| Script | What it does | Where | Example |
| --- | --- | --- | --- |
| `jobs/benchmark.sh` | Oceananigans' benchmark suite (hydrostatic `earth_ocean`) on any number of GPUs | job | `bash jobs/submit_gpu.sh jobs/benchmark.sh 8` |
| `jobs/submit_hydro_nccl.sh` | The hydrostatic MPI vs NCCL set: 1 GPU, then 1, 2 and 4 full nodes | login | `bash jobs/submit_hydro_nccl.sh` |
| `jobs/benchmark_cpu.sh` | The same suite on one full CPU node, for comparison with a GPU | job | `sbatch --ntasks=48 --cpus-per-task=4 jobs/benchmark_cpu.sh` |
| `jobs/benchmark_nh.sh` | The nonhydrostatic box benchmark (`benchmarks/nonhydrostatic_box.jl`) | job | `bash jobs/submit_gpu.sh jobs/benchmark_nh.sh 4` |
| `jobs/benchmark_poisson.sh` | The pressure solver alone (`benchmarks/poisson_solver.jl`), MPI or NCCL | job | `bash jobs/submit_gpu.sh jobs/benchmark_poisson.sh 4 --export=ALL,COMM=NCCL` |
| `jobs/submit_poisson_scaling.sh` | The pressure-solver MPI vs NCCL set at 512²×256, strong and weak (17 jobs) | login | `bash jobs/submit_poisson_scaling.sh` |
| `jobs/submit_poisson_1024.sh` | The pressure solver at 1024³ in Float32 on 1–8 GPUs (7 jobs) | login | `bash jobs/submit_poisson_1024.sh` |
| `tools/summarize_benchmarks.py` | One Markdown table (times, efficiencies, memory) from the suite's JSON results | any | `python3 tools/summarize_benchmarks.py results/*.json` |
| `tools/plot_scaling.py` | The hydrostatic scaling figure (time and efficiency vs GPUs) from the table in `results/hydrostatic_scaling.md`; needs matplotlib | any | `python3 tools/plot_scaling.py` |

Results: `grep -ah "^RESULT" logs/<job name>_*.out` for the `benchmarks/` scripts, and
`summarize_benchmarks.py` for the suite. Details: [benchmarks/README.md](../benchmarks/README.md).

## Julia files run by the scripts above

Not run by hand, listed so nothing is a mystery: `checks/*.jl` (run by `jobs/checks.sh`),
`tests/platform.jl` and `tests/viz.jl` (by `tools/run_tests.sh`), `benchmarks/*.jl` (by the
benchmark jobs), `tools/check_project.jl` (by `tools/check_env.sh`), `src/drac_mpi.jl` (included
by scripts that start MPI; see [drac.md](drac.md), step 7), and `examples/hello_oceananigans.jl`
(by the hello jobs).

## Adding a script

Start it with a header comment that says what it does and shows how to run it, and add the `-h`
line the other scripts have (it prints that header). Then add it to this page:
`tests/ci/check_scripts_documented.py` fails the automatic checks for any script that is missing
here or has no usage in its header.

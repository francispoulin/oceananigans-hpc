# Roadmap

What this repository is for: one tested environment for Oceananigans on every machine we use
(Alliance clusters with Slurm; pelee/rondeau without), plus the tools around it: setup, MPI
configuration, plotting environment, launcher, checks, platform tests and benchmarks. Simulation
repositories depend on it by convention, not as a Julia package, and dependencies point one way:
this repository never depends on a simulation repository.

Boxes are ticked in the pull request that does the work. Last updated: October 27, 2026.
Versions: see [CONTRIBUTING.md](CONTRIBUTING.md#versions-and-releases).

## Phase 1: finish and stabilize

- [x] Platform tests (`tools/run_tests.sh`) pass on Nibi, Fir, Rorqual, Trillium and rondeau (Oct 13)
- [x] Trillium supported: output on `$SCRATCH`, writable compiled cache in jobs, whole-GPU requests
- [x] Two settings for fast GPU-to-GPU communication: `--gpus-per-node` (never `--gpus-per-task`)
      and the CUDA.jl memory pool off; documented in `docs/drac.md`, step 7
- [x] `jobs/submit_gpu.sh`: any GPU job on N GPUs with the right Slurm options for the cluster
- [x] Checks and platform tests run with every rank seeing its node's GPUs (check verified on
      Rorqual, Oct 16)
- [x] How changes are made: [CONTRIBUTING.md](CONTRIBUTING.md)
- [x] Every script listed in [docs/scripts.md](docs/scripts.md), with its usage printed by `-h`
- [x] Platform tests rerun with the Oct 15–16 settings
  - [x] rondeau (Oct 16: 21 passed, same answers as Oct 13)
  - [x] Nibi (Oct 19, in v0.2.0)
  - [x] Fir (Oct 17)
  - [x] Rorqual (Oct 16)
  - [x] Trillium (Oct 17)
- [x] Test summaries committed; `docs/drac.md` section 10 ("Tested with") updated
- [x] Every clone clean and set to `pull.ff only`: Nibi, Fir, Rorqual, Trillium, pelee/rondeau
- [x] `main` protected on GitHub (pull requests and the automatic checks required)
- [x] Automatic checks on every pull request (`tests/ci/`): shell syntax, `shellcheck`, submit
      scripts' Slurm options for each cluster, links in the docs
- [x] Repository renamed oceananigans-hpc (was Oceananigans-DRAC); `OCEAN_HPC_ROOT` replaces
      `OCEANANIGANS_DRAC_ROOT` (exported until v0.3.0, removed in v0.4.0)
- [x] Every clone's remote points to the new name (`git remote set-url`)
- [x] Each cluster fact in one place: `jobs/gpu_request.sh` (GPUs per node, memory, Trillium's
      rules), used by every script; the docs' tables are checked against it automatically
- [x] Release **v0.1.0** (Oct 17): tested on Fir, Rorqual, Trillium and rondeau
- [x] Release **v0.2.0** (Oct 19): contract for simulation repositories (Phase 3), Julia 1.10.10 everywhere,
      tested on every machine including Nibi
- [x] Release **v0.3.0** (Oct 19): long option names for `tools/run_local.sh`; tested on rondeau
- [x] Release **v0.4.0** (Oct 20): `OCEANANIGANS_DRAC_ROOT` removed, Trillium job folder renamed; branches
      tested in a worktree, summaries published from the machines, Buildkite on pelee; tested on
      Trillium, Rorqual and pelee

## Phase 2: complete the switch of pelee and rondeau to this setup

- [x] `setup/configure_mpi.sh` on the simulation project folders (BeaufortGyreSimulations,
      Gulf-Stream-Asymmetry); one regression run each with the new setup: norms bitwise identical
      to the old setup (Oct 14)
- [x] Old module-based setup removed: module block out of `~/.profile`, ocean data (ECCO, EN4,
      ETOPO; 136 files) copied to the shared drive, old `~/.julia` depot deleted (Oct 18)
- [x] `OCEAN_DATA_DIR` in every env file and in the contract (`env/README.md`), with how it relates
      to `OCEAN_JOB_DIR`
- [x] One Julia on every machine: 1.10.10 on pelee/rondeau too (`setup/install_julia.sh`; the
      modules there stop at 1.10.8); setup and platform tests rerun on pelee and rondeau (Oct 18: 21 passed on each)

## Phase 3: serve the simulation repositories (platform side only)

- [x] Contract for a simulation repository ([docs/simulation_repos.md](docs/simulation_repos.md)):
      its own `Project.toml` without Makie; plotting in `viz/`; what it can rely on
- [x] `OCEAN_RESULTS_ROOT` set by the environment: `$SCRATCH/results` (Alliance),
      `/mnt/autofs/bow.math/scratch/$USER/results` (pelee/rondeau, shared); repositories write under
      `$OCEAN_RESULTS_ROOT/<repository>/`
- [x] A job script for simulation repositories, submitted with `jobs/submit_gpu.sh` (which now takes
      other repositories' scripts, and script options after `--`); `tools/run_local.sh` on pelee/rondeau
- [x] Platform tests that simulation repositories rely on (their own regression tests live in
      those repositories)
- [x] Long option names for `tools/run_local.sh` (`--gpus`, `--gpu-ids`, `--project`, `--job-name`;
      `--name=value` too), asked for by BalancedFlows; the short forms (`-n`, `-g`, `-p`, `-j`) still work
- [x] BalancedFlows uses the contract: `OCEAN_HPC_ROOT`, `submit_gpu.sh` for multi-GPU runs on the
      Alliance, `$OCEAN_RESULTS_ROOT/BalancedFlows/` (BalancedFlows v0.7.0; old name dropped in its #27)
- [x] Then drop `OCEANANIGANS_DRAC_ROOT` (v0.4.0); `ocean_setup` points out `~/.bashrc` lines that still use it
- [x] Trillium job folder `$SCRATCH/oceananigans-hpc` (was `oceananigans-drac`) in `env/drac.sh`
- [x] Folders renamed on Fir, Rorqual, Trillium and pelee/rondeau: clones `Oceananigans-DRAC` → `oceananigans-hpc`
      (README), and on Trillium `$SCRATCH/oceananigans-drac` → `oceananigans-hpc`
- [x] Nibi on the new clone (Oct 28, after its queued scaling jobs ended): `ocean_setup` alias to
      `oceananigans-hpc`, our own Julia, platform tests (21 passed); old clone renamed
      `Oceananigans-DRAC.old-20261028`, to delete once nothing is missed
- [x] Nonhydrostatic benchmark: Oceananigans' own nonhydrostatic box (`benchmarks/nonhydrostatic_box.jl`,
      results in `results/nonhydrostatic_rondeau.md`), as for the hydrostatic model (`earth_ocean`). No
      BalancedFlows configuration (decided Oct 20: benchmarks use Oceananigans' cases; a harness for its own
      configurations is on BalancedFlows' wish list)
- [x] v1.0.0: a stable baseline before any library changes (Phase 4), in this order (agreed Oct 20):
  - [x] Test a branch without switching the clone (`tools/test_branch.sh`, a worktree), and publish
        test summaries from the machines (`tools/publish_summary.sh`)
  - [x] Our own Julia 1.10.10 on the Alliance clusters too (`setup/install_julia.sh`, `env/drac.sh`
        without the `julia` module), the same version, so 1.0.0 starts on the setup we keep
    - [x] `env/julia.sh`, one place for every machine: our install next to the depot, else the module
    - [x] Installed and tested on Rorqual and Trillium (Oct 21, 6bf3999, 21 of 21 each; pelee by Buildkite)
    - [x] Installed on Fir, with its new clone
    - [x] Installed on Nibi, with its new clone (Oct 28)
  - [x] Platform tests at one commit on the machines a 1.0.0 needs (Oct 27–28: Trillium, pelee and
        rondeau at 3d16f3e, Nibi at 1027177, docs only since; Nibi stands for Fir and Rorqual, Rorqual
        being in maintenance; CONTRIBUTING.md, "Making a release")
  - [x] BalancedFlows has used the contract on pelee and one Alliance cluster (Oct 28, quick tier at
        1027177: pelee 15/15 bitwise; Nibi 11/15, the other four 1–2 rounding units from the A100
        references in the norms, H100 summation order, its own tests' tolerance to change, not this setup)

## Phase 4: a workflow for updating libraries

Oceananigans, Julia, the GPU stack (CUDA.jl, GPUCompiler, LLVM), MPI.jl/OpenMPI_jll, NCCL, cluster
modules and the plotting stack all change independently. Libraries change only after v1.0.0; the
scripts below are built and tried on pelee/rondeau before then (they never touch the main
environment). Oceananigans, a package, tests ranges of versions; this repository pins exact ones
(`Manifest.toml`), so an upgrade is a deliberate change of pins, tested on the machines.

- [ ] `setup/make_candidate.sh <package>@<version>`: `envs/candidate` from the main environment with one
      package upgraded, MPI configured, precompiled
- [ ] `tools/run_tests.sh --project envs/candidate` (and `tools/test_branch.sh`) to test it
- [ ] `tools/versions.sh`: the versions of every environment (main, `viz`, `envs/nccl`, the benchmark suite)
- [ ] `setup/setup_benchmark_suite.sh <commit>`: the suite follows the Oceananigans version
- [ ] Automatic GPU tests on pelee/rondeau for every pull request, with Buildkite as Oceananigans
      does ([docs/ci.md](docs/ci.md); decided Oct 20: a GitHub Actions runner is advised against for
      public repositories, a poller gives no check on the pull request)
  - [x] Pipeline (`.buildkite/pipeline.yml`) and `tools/ci_platform_tests.sh`
  - [x] Trial: agent on pelee under a personal account; first green build (Oct 21–26; builds `main` and
        pull requests only since #39)
  - [ ] Agreed with the servers' administrators: a dedicated account (being created, Oct 27), the agent
        as a service
  - [ ] Move the agent to that account: its own Julia 1.10.10 and depot (it can't use a personal one), the
        agent as a service, one green build; `docs/ci.md` updated
  - [ ] Then BalancedFlows' pipeline on the same agent (after this repository's first green build there,
        so a failure has one cause); then rondeau
  - [ ] Later, if the cluster's staff agree: one Alliance cluster (Slurm jobs started from Buildkite,
        as CliMA's slurm-buildkite does)

- [ ] One upgrade at a time, in a separate environment (`envs/candidate`), never in the main one;
      read the release notes first
- [ ] Test on rondeau first (platform tests, benchmarks, one short run of each simulation
      repository), then on one cluster; compare with the stored summaries
- [ ] Adopt in one pull request listing the versions, then setup and tests on every machine and a
      new release tag; or write down why not and what to wait for
- [ ] Record the versions of every environment, including `envs/nccl` (not under version control)
- [ ] Benchmarks: the suite is pinned (`setup/setup_benchmark_suite.sh`, commit 8743c40d0) and its
      `benchmarking/` in 0.113.5 has only `earth_ocean`; `benchmarks/nonhydrostatic_box.jl` ports the newer
      suite's nonhydrostatic case. On an upgrade, re-pin the suite and check whether its nonhydrostatic
      case can replace the port (same configuration, so results stay comparable)
- [ ] First uses, after v1.0.0:
  - [x] Oceananigans 0.116.1 on Julia 1.10.10 (v1.1.0, Oct 28; tested on pelee and Trillium)
  - [ ] Julia 1.13 (Oceananigans tests with it; our own install), after the tridiagonal-solver fix is
        merged in Oceananigans

## Phase 5: scaling numbers

- [x] Pressure solve (1024³, Float32), MPI vs NCCL, 1–8 GPUs: Trillium and Rorqual; Nibi 1–4 GPUs
- [ ] Nibi pressure solve on 8 GPUs (one node)
- [x] Hydrostatic strong scaling with both settings: Nibi 1–32 GPUs (MPI; NCCL at 8–32),
      Trillium and Rorqual up to 16 GPUs (NCCL on 32: 64% against MPI's 59%, Oct 27); Rorqual 1/8° on
      4–16 GPUs: 99% and 94%
- [x] Hydrostatic weak scaling on Nibi with both settings (4, 16, 64 GPUs; 64 also with a 2-D split):
      98%, 97%, and on 64 GPUs (8 nodes) 87% split in x, **98% split 8 × 8** (Oct 27)
- [ ] Results name their code: repository commit and Oceananigans commit in every table
- [x] Results pages `results/hydrostatic_scaling.md` (with its figure, `tools/plot_scaling.py`) and
      `results/pressure_solver_1024.md`; `docs/drac.md` section 8 rewritten from them (Oct 20)
- [ ] Fill the queued rows as runs finish (Nibi 8-GPU pressure solve, Fir 8-GPU NCCL pressure solve; Nibi
      NCCL on 16, weak 16 and 64 and NCCL on 32 done)
- [ ] Update to the Discussion posts (the 8 × 8 weak-scaling result is worth one: 98% on 8 nodes)

## Later

- [ ] pelee/rondeau: MPI moves GPU buffers at half NCCL's speed within the node (1024³ transposes 71 vs
      36 ms, Oct 22; OpenMPI 4.1.7 with `smcuda`, no UCX). Try `smcuda` settings (CUDA IPC), or ask for
      an OpenMPI built with UCX; meanwhile NCCL for nonhydrostatic runs there
- [ ] pelee/rondeau, in the Oceananigans 0.116.1 round: the `cuda/12.3.2` module puts its libraries on
      `LD_LIBRARY_PATH`, and the newer CUDA.jl loads `libcusparse`/`libnvJitLink` 12.3 from there
      instead of its own (warning seen with Oceananigans PR #6314's branch, Oct 22). Test removing the
      module's `lib64` from `LD_LIBRARY_PATH` after loading OpenMPI in `env/fluidsgpu.sh`

- [ ] **Re-evaluate the tests, here and in BalancedFlows** (Francis, Oct 21): what each test checks,
      how long it runs, and where (pelee by Buildkite, Trillium's debug queue: 1 h, 2 nodes, one job at
      a time), so most testing needs no long queue. Record each job's actual run time next to its
      results (e.g. an elapsed column in `tools/summarize_benchmarks.py`) and set time requests from it
      (about 2 to 3 times the run time); lower the job scripts' defaults (benchmarks ask 45–80 min and
      run 8–16, Oct 21); let `jobs/submit_gpu.sh` use Trillium's debug queue for jobs that fit

- [ ] **Hydrostatic multi-GPU no longer bitwise** (Oceananigans 0.116.1, Oct 26): 4 vs 1 GPU differs by
      4.4e-13 after 30 steps (hydro_box, 128 cells in x) and grows like a one-rounding-unit change of the initial state, so it is
      round-off (tests/README.md). Revisit if it ever grows faster than that, or to find the release
      that changed it (0.114, 0.115 or 0.116.0) if the Oceananigans developers want to know.
- [x] **Test jobs ask for 20 minutes, too tight** (Oct 27): on Fir a platform test at 3d16f3e passed 20 of
      21 steps and was stopped by the limit before `viz`, so no summary was written (twice; the third try
      passed). `test_job_request` in `jobs/gpu_request.sh` now asks for 30 minutes (about 3 times a normal
      run), v1.1.0
- [ ] **Fir's 1-GPU test step took 672 s** (Oct 27; 205 s on Trillium, tests about 180 s of it), with no
      package precompiling in its log; its 4-GPU step was normal (285 s). Cause unknown (shared file
      system?): look at the step's own timings if it happens again
- [ ] Point the Waterloo Fluids Computing Handbook's Oceananigans pages to this workflow
- [ ] Shared depot for the group on pelee/rondeau, once several people use it
- [ ] GPU tests on every pull request (a self-hosted runner on pelee)
- [ ] Download script for the ocean data sets
- [ ] `run_local.sh`: reserve the GPUs it hands out for a few minutes, so runs started together
      without `-g` cannot pick the same GPU (documented for now; fix if it bites)
- [ ] Contribute multi-GPU nonhydrostatic cases to the Oceananigans benchmark suite
- [ ] MPI between nodes with GPUDirect RDMA
- [ ] Faster local work in the distributed pressure solve (the 1 → 2 GPU cost)
- [ ] A short guide for new users running the MPI vs NCCL comparisons

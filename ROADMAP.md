# Roadmap

What this repository is for: one tested environment for Oceananigans on every machine we use
(Alliance clusters with Slurm; pelee/rondeau without), plus the tools around it: setup, MPI
configuration, plotting environment, launcher, checks, platform tests and benchmarks. Simulation
repositories depend on it by convention, not as a Julia package, and dependencies point one way:
this repository never depends on a simulation repository.

Boxes are ticked in the pull request that does the work. Last updated: October 19, 2026 (v0.2.0).
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
- [ ] Folders renamed on every machine: clones `Oceananigans-DRAC` → `oceananigans-hpc` (README), and on
      Trillium `$SCRATCH/oceananigans-drac` → `oceananigans-hpc`; Nibi and Fir once their queued jobs end
- [x] Nonhydrostatic benchmark: Oceananigans' own nonhydrostatic box (`benchmarks/nonhydrostatic_box.jl`,
      results in `results/nonhydrostatic_rondeau.md`), as for the hydrostatic model (`earth_ocean`). No
      BalancedFlows configuration (decided Oct 20: benchmarks use Oceananigans' cases; a harness for its own
      configurations is on BalancedFlows' wish list)
- [ ] v1.0.0: a stable baseline before any library changes (Phase 4), in this order (agreed Oct 20):
  - [x] Test a branch without switching the clone (`tools/test_branch.sh`, a worktree), and publish
        test summaries from the machines (`tools/publish_summary.sh`)
  - [ ] Our own Julia 1.10.10 on the Alliance clusters too (`setup/install_julia.sh`, `env/drac.sh`
        without the `julia` module), the same version, so 1.0.0 starts on the setup we keep
    - [x] `env/julia.sh`, one place for every machine: our install next to the depot, else the module
    - [x] Installed and tested on Rorqual and Trillium (Oct 21, 6bf3999, 21 of 21 each; pelee by Buildkite)
    - [ ] Installed on Nibi and Fir (with their rename)
  - [ ] Folders renamed on Nibi and Fir (item above)
  - [ ] Platform tests on every machine at one commit; BalancedFlows has used the contract on each

## Phase 4: a workflow for updating libraries

Oceananigans, Julia, the GPU stack (CUDA.jl, GPUCompiler, LLVM), MPI.jl/OpenMPI_jll, NCCL, cluster
modules and the plotting stack all change independently. Libraries change only after v1.0.0; the
scripts below are built and tried on pelee/rondeau before then (they never touch the main
environment). Oceananigans, a package, tests ranges of versions; this repository pins exact ones
(`Manifest.toml`), so an upgrade is a deliberate change of pins, tested on the machines.

- [ ] Automatic GPU tests on pelee/rondeau for every pull request, with Buildkite as Oceananigans
      does ([docs/ci.md](docs/ci.md); decided Oct 20: a GitHub Actions runner is advised against for
      public repositories, a poller gives no check on the pull request)
  - [x] Pipeline (`.buildkite/pipeline.yml`) and `tools/ci_platform_tests.sh`
  - [ ] Trial: agent on pelee under a personal account; first green build
  - [ ] Agreed with the servers' administrators: a dedicated account, the agent as a service
  - [ ] rondeau; then BalancedFlows on the same agents
  - [ ] Later, if the cluster's staff agree: one Alliance cluster (Slurm jobs started from Buildkite,
        as CliMA's slurm-buildkite does)

**How a library upgrade is done (agreed Oct 24).** Upgrades are rounds, each ending in one release:

- **When:** a new minor Oceananigans release (0.116 → 0.117) is worth a round; patch releases
  (0.116.1 → 0.116.2) wait for the next one. Julia changes when Oceananigans or a package needs it.
- **Released versions only**, pinned in `Manifest.toml`; never Oceananigans' `main`.
- **Read the release notes of every version skipped, then go straight to the latest.** Step back
  version by version only if something breaks (cheap: on pelee).
- **Both knobs in one round** (Oceananigans and Julia) to save cluster tests; split the round only if
  it fails, and learn from experience how often that happens.
- **pelee does the work, Trillium confirms:** pelee has no queue, Trillium's debug queue starts in
  minutes. Other machines are updated with a pull and `install_julia.sh`, and tested under the
  normal release rule (CONTRIBUTING.md).
- **The main environment is untouched until adoption:** the candidate is a separate worktree.
- **Version number:** an upgrade is a MINOR release (simulation repositories pin their own
  Oceananigans in their own `Manifest.toml`, so they are not changed by it).
- **Simulation repositories upgrade afterwards, on their own schedule** (BalancedFlows: its own
  candidate on pelee and its full tier).

Tools:
- [ ] `setup/make_candidate.sh [--julia X.Y.Z] Package@version`: `<clone>-candidate` worktree from
      `origin/main`, packages upgraded, MPI set up, precompiled, versions that changed printed;
      `--push <branch>` makes it a branch for `tools/test_branch.sh` (draft on `claude/library-upgrade`)
- [ ] `tools/compare_speed.sh`: the pressure-solver benchmark in the clone and the candidate, back to
      back, one table and a verdict (`--b-script` for an experiment, `--profile` for time per kernel,
      `--report` for two logs)
- [ ] `tools/test_branch.sh` installs a branch's Julia and packages first (an upgrade branch)
- [ ] `setup/install_julia.sh <version>`: another Julia than the Manifest's
- [ ] `setup/setup_benchmark_suite.sh <commit>`: the suite follows the Oceananigans version
- [ ] `tools/versions.sh`: the versions of every environment (main, `viz`, `envs/nccl`, the benchmark suite)

**First round, after v1.0.0: Oceananigans 0.113.5 → 0.116.1 and Julia 1.10.10 → 1.13.2**
(0.116.1 still allows Julia 1.10; Oceananigans' own tests run on 1.13.2 and pin `CUDA_Runtime_jll` 12.9):
- [ ] 0. Before: pelee's `cuda/12.3.2` module and `LD_LIBRARY_PATH` (item in *Later*); read the
      release notes of 0.114, 0.115 and 0.116 (breaking changes for `tests/platform.jl`,
      `benchmarks/*.jl`, `src/`)
- [ ] 1. pelee: `bash setup/make_candidate.sh --julia 1.13.2 Oceananigans@0.116.1`
- [ ] 2. pelee: platform tests in the candidate (21 steps, ~10 min)
- [ ] 3. pelee: does the physics change? BalancedFlows' quick tier with the candidate against its
      references (not necessarily bitwise across versions; small and explained by the release notes)
- [ ] 4. pelee: speed: `bash tools/compare_speed.sh` (1024³ on 4 GPUs, MPI; main reproduced Oct 22's
      158.9 ms). Oct 25: **B 20% slower** (191.9 ms; transposes the same, the rest +32 ms; `p_std`
      agrees); suspected cause: Oceananigans #6161 adds `x .-= mean(x)` to every distributed
      Fourier-tridiagonal solve (#6189 removed the same from the 1-GPU solver): undoing it gives 186.5 ms
      and main's `p_std` bitwise, so #6161 costs 5.5 ms; the other 27 ms (same arithmetic) are being
      profiled (`compare_speed.sh --b-script ... --profile`)
- [ ] 5. `--push upgrade/oceananigans-0.116.1-julia-1.13.2`; Claude adds the notes (what changed, from
      the release notes and the version list) and re-pins the benchmark suite; pull request
- [ ] 6. The pull request on pelee and in Trillium's debug queue (`tools/test_branch.sh <branch>`)
- [ ] 7. Merge; release v1.1.0; the other machines pull and run `setup/install_julia.sh`
- [ ] 8. BalancedFlows: its own round

## Phase 5: scaling numbers

- [x] Pressure solve (1024³, Float32), MPI vs NCCL, 1–8 GPUs: Trillium and Rorqual; Nibi 1–4 GPUs
- [ ] Nibi pressure solve on 8 GPUs (one node)
- [ ] Hydrostatic strong scaling with both settings: Nibi 1–32 GPUs (MPI; NCCL at 8–32),
      Trillium and Rorqual up to 16 GPUs
- [ ] Hydrostatic weak scaling on Nibi with both settings (4, 16, 64 GPUs; 64 also with a 2-D split)
- [ ] Results name their code: repository commit and Oceananigans commit in every table
- [x] Results pages `results/hydrostatic_scaling.md` (with its figure, `tools/plot_scaling.py`) and
      `results/pressure_solver_1024.md`; `docs/drac.md` section 8 rewritten from them (Oct 20)
- [ ] Fill the queued rows as runs finish (Nibi NCCL, Nibi 8-GPU pressure solve, weak 16 and 64)
- [ ] Update to the Discussion posts

## Later

- [ ] **Re-evaluate the tests, here and in BalancedFlows** (Francis, Oct 21): what each test checks,
      how long it runs, and where (pelee by Buildkite, Trillium's debug queue: 1 h, 2 nodes, one job at
      a time), so most testing needs no long queue. Record each job's actual run time next to its
      results (e.g. an elapsed column in `tools/summarize_benchmarks.py`) and set time requests from it
      (about 2 to 3 times the run time); lower the job scripts' defaults (benchmarks ask 45–80 min and
      run 8–16, Oct 21); let `jobs/submit_gpu.sh` use Trillium's debug queue for jobs that fit

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

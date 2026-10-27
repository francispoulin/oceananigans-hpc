# How changes are made

This repository runs on several machines (Nibi, Fir, Rorqual, Trillium, pelee/rondeau), each with
its own clone. The workflow below keeps every clone identical to `main` on GitHub, so that a result
can always be traced to the code that produced it. It applies to everyone, maintainers included.

## The rules

1. **Every change goes through a branch and a pull request.** Nothing is committed directly to
   `main` (GitHub enforces this).
2. **Clones on the machines only pull, and stay on `main`.** Never edit files in a machine's clone.
   A branch is tested in a separate worktree with `tools/test_branch.sh` (see "Testing a branch"
   below), so the clone never switches. The one thing a machine pushes is a test summary, with
   `tools/publish_summary.sh`, on its own `results/...` branch. Experiments that are not meant to be
   committed go in `local/` (ignored by git), not among the tracked files.
3. **Clones refuse to merge on pull.** Set once on every machine:
   `git config --global pull.ff only`. A clone that has drifted then stops with an error instead of
   quietly creating a merge commit, so the drift is noticed and fixed.
4. **Branch names start with the author's initials:** `<initials>/<what-it-does>`, for example
   `fjp/weak-scaling-docs` (Francis) or `claude/submit-gpu-memory` (Claude). It shows at a glance
   whose branch it is, and keeps everyone's branches apart.
5. **One logical change per pull request.** A behaviour change and its documentation can go
   together; unrelated fixes go in separate pull requests.
6. **Test before merging, on the machine the change affects** (table below).
7. **Pull everywhere after merging**, so every machine runs the same code.
8. **The repository is public.** No personal names other than the authors, no account or
   allocation names (use `def-yourpi` in examples), no credentials or tokens.

## Where to edit and where to test

Edit wherever is convenient (a laptop, or a clone on pelee/rondeau), as long as the change is
committed on a branch and pushed before it runs anywhere else.

Tests go where they are quick. pelee is tested on every pull request by itself (Buildkite,
[docs/ci.md](docs/ci.md)); Trillium's debug queue starts a test in about 10 minutes
(`tools/run_tests.sh` uses it); Rorqual, Nibi and Fir can wait hours to a day, so they are tested
at releases and for changes aimed at them, not for every pull request.

| Kind of change | Test on | How |
| --- | --- | --- |
| Shell syntax, Slurm options of submit scripts, docs links | Anywhere (also run automatically on every pull request) | `bash tests/ci/run_all.sh` |
| Anything (every pull request) | pelee, automatically | Buildkite: the check on the pull request |
| Julia code, environment files, 1–4 GPU behaviour | pelee (automatic) or rondeau | `bash tools/test_branch.sh <branch>` |
| The Alliance setup (`env/drac.sh`, `env/julia.sh`, `setup/`, `jobs/`, Slurm options) | **Trillium** (debug queue, ~10 min wait) | `bash tools/test_branch.sh <branch>` on trig-login01 |
| What only runs off Trillium (`--mem`, `h100` GPUs, Nibi's 8 GPUs per node, a cluster's own fix) | The cluster concerned | `bash tools/test_branch.sh <branch>` there |
| Package or module upgrades | rondeau first, then one cluster | `ROADMAP.md`, Phase 4 |

## How results are compared

- **The same run repeated** (checkpoint and restart, the same command twice on one GPU): **bitwise**.
- **Across decompositions (1 vs N GPUs), machines or library versions:** relative difference **below
  1e-8, on short runs** (tens of steps). There, healthy round-off is 1e-14 to 1e-12, and the real
  problems found so far were 1e-7 or more (Oct 22: a WENO smoothness indicator that amplified
  round-off, 1 vs 4 GPUs 3e-7 to 1.5e-5 after 16 steps). Never assume bitwise here: since Oceananigans
  0.116.1, hydrostatic 4 vs 1 GPU is round-off, no longer bitwise.
- **Long runs** of an unstable flow amplify round-off past any tolerance, so they are compared on
  physical quantities (norms, energy, growth rates), not on fields.
- **Speed is not tested by any of these:** a slowdown with identical results (Julia 1.13's tridiagonal
  solve, Oct 26) shows only in timings, so a library upgrade also compares speed (`ROADMAP.md`, Phase 4).

Simulation repositories that build on this one can use the same rule for their own tests.

## Step by step

```bash
# 1. Start from an up-to-date main
cd "$OCEAN_HPC_ROOT"
git switch main && git pull

# 2. Make a branch: your initials, then what it does; edit, commit
git switch -c fjp/submit-gpu-memory
# ... edit ...
git add -p                       # review each change as you stage it
git commit                       # message: see below

# 3. Push and open a pull request on GitHub
git push -u origin fjp/submit-gpu-memory
```

**Testing a branch on a machine** (a cluster, or pelee/rondeau), one command, from anywhere:

```bash
bash /path/to/oceananigans-hpc/tools/test_branch.sh fjp/submit-gpu-memory
```

It checks the branch out in a git worktree next to the clone (`<clone>-test`), copies the clone's
machine-specific `LocalPreferences.toml` into it, and runs the platform tests there with the
worktree's own environment. The clone stays on `main`, so jobs already queued from it are never
affected. On pelee/rondeau the tests run at once if enough GPUs are free (otherwise nothing runs),
and the summary is published at the end if nothing failed or was skipped; on a cluster one job is
submitted, and once it has ended, `bash tools/publish_summary.sh --if-clean --latest` publishes the
summary. One test at a time per machine: a lock in the worktree stops a second one.
Other runs of a branch (a benchmark, a job of your own) are started from the worktree in the same
way: `source <clone>-test/env/ocean_setup.sh`, then the usual command. `test_branch.sh --clean`
removes the worktree.

**Merging:** on the pull request page, check the diff and that the automatic checks pass, then
*Merge*. Delete the branch (GitHub offers a button). Then on every machine:

```bash
cd "$OCEAN_HPC_ROOT" && git switch main && git pull
```

If `git pull` stops with `Not possible to fast-forward`, the clone has local commits or edits:
`git status` and `git log origin/main..` show them. Keep them on a branch (`git switch -c ...`) or
discard them (`git reset --hard origin/main`, after checking they are not needed).

## Results produced on a machine

Test summaries (`results/tests/`) and benchmark results are written on the machine that ran them.
A test summary is the one file a machine pushes, with one command:

```bash
bash tools/publish_summary.sh results/tests/nibi_20261016-2022.md    # or --latest
```

It commits that file alone on top of `origin/main`, as a new branch `results/nibi_20261016-2022`,
and pushes it, without touching the clone (no checkout, no local commit, so nothing blocks the next
`git pull`). The branch is then merged into the pull request that needs it, and deleted. Benchmark
tables are pasted into a pull request as before. Every summary records the commit it was run with,
so a result always points to its code.

## Commit messages

A first line under about 70 characters naming what changed, then a blank line and the reason:

```
gpu_request.sh: GPUs per node follow the cluster (8 on Nibi)

GPUS_PER_NODE defaulted to 4 everywhere, so on Nibi a 4-GPU job asked for
--mem=0 on half a node and sbatch refused it.
```

## Versions and releases

Versions follow [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`. What counts is what
users rely on, this repository's *public interface*: the script names and their arguments, the
environment variables in the contract ([env/README.md](env/README.md)), the paths job scripts point
to (`env/ocean_setup.sh`, `src/drac_mpi.jl`, `viz/`), and the package versions in `Manifest.toml`.

| Bump | When | Examples |
| --- | --- | --- |
| PATCH (0.1.0 → 0.1.1) | Fixes and docs; nobody needs to change anything | A clearer error message; a docs correction |
| MINOR (0.1.x → 0.2.0) | New things; the old usage still works | A new script or benchmark; a new cluster; a new optional variable |
| MAJOR (1.x → 2.0.0) | Something users rely on changes or disappears | Renaming a script or a contract variable; a required argument; an Oceananigans upgrade that breaks user code |

Before 1.0 (`0.y.z`, while the interface is still settling) a breaking change bumps the minor number
and everything else the patch number. 1.0.0 comes once the contract for simulation repositories is
settled (`ROADMAP.md`, Phase 3). A breaking change keeps the old way working for one minor version
where it can, with a note saying when it goes (for example `OCEANANIGANS_DRAC_ROOT`, the variable's
name before the repository was renamed, was exported alongside `OCEAN_HPC_ROOT` from v0.1.0 to v0.3.0
and removed in v0.4.0).

**Making a release:**

1. The platform tests (`tools/run_tests.sh`) pass at the commit to release, on the machines below;
   their summaries are committed. The queues make testing every cluster slow, so how many depends
   on what changed since the last release:
   - **Only the numbers can change** (package versions, Julia code the tests run): **one** Alliance
     cluster, any of Nibi, Fir, Rorqual and Trillium.
   - **The setup can change** (`env/`, `setup/`, `jobs/`, `tools/run_tests.sh`, Slurm options):
     **two** clusters, one of them Trillium, which differs most (no writing to `/project` in jobs,
     a clean job environment, 1 GPU or whole nodes), the other usually Rorqual. A change aimed at one
     cluster (for example Nibi's 8 GPUs per node or its Slurm path) is tested on that cluster. This is
     where Rorqual (or Nibi, Fir) is tested "every so often": pull requests merge on pelee and
     Trillium, and a release catches what only shows elsewhere before anyone depends on it.
   - **pelee or rondeau** as well, when `env/fluidsgpu.sh`, `tools/run_local.sh` or anything else
     they use changed (no queue there).
   - **Every machine** for 1.0.0 and for upgrades of Julia, Oceananigans or the GPU stack
     (ROADMAP.md, Phase 4).

   Machines not retested keep their last summary; the "Tested with" table says which version it was.
   The automatic checks (`tests/ci/`) cover the Slurm options of every cluster on every pull request.
2. `version` in `Project.toml` and section 10 of `docs/drac.md` ("Tested with") are updated in a
   pull request.
3. After merging, tag the merged `main` with an annotated tag and push it, in one chained command
   so that nothing is tagged if the pull fails (for example because of a test summary left on the
   machine; remove it first):
   ```bash
   git switch main && git pull --ff-only && git describe --tags && \
   git tag -a v0.2.1 -m "v0.2.1: ..." && git push origin v0.2.1
   ```
   Check that `git rev-parse --short "v0.2.1^{commit}"` is the merge of the release pull request.
   A tag is never moved once its release is published; a mistake is fixed with the next version.
4. On GitHub, *Releases → Draft a new release*, pick the tag and *Generate release notes* (the list
   of merged pull requests). Above that list, paste the release notes from the release pull request
   **as raw Markdown**: copy them from the pull request's *Edit* box (or from a code block), not from
   the rendered page, and use full links (`https://github.com/.../blob/vX.Y.Z/docs/...`), since
   relative links do not work in a release.

Results, test summaries and upgrade notes refer to these versions.

## New scripts

A new script starts with a header comment saying what it does and how to run it, has the `-h`
line the other scripts have (it prints that header), and is added to
[docs/scripts.md](docs/scripts.md). The automatic checks fail otherwise.

## New machines and other contributions

Corrections and other clusters are welcome: open an issue or a pull request. A new machine needs an
`env/<machine>.sh` providing the variables in [env/README.md](env/README.md), and a case in
`env/ocean_setup.sh`.

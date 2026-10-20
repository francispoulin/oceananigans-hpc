# Using oceananigans-hpc from a simulation repository

Simulation code lives in its own repository (BalancedFlows.jl, for example), not here. This page is
the contract between the two: what a simulation repository can rely on, and what it does itself.
Everything listed under "What you can rely on" is this repository's public interface: it changes only
with a new version, and a change that breaks it keeps the old way working for one minor version
(see [CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-releases)).

## What you can rely on

**After `source $OCEAN_HPC_ROOT/env/ocean_setup.sh`** (the `ocean_setup` alias), on every machine:

| Variable | Use it for |
| --- | --- |
| `OCEAN_HPC_ROOT` | the paths below |
| `OCEAN_MACHINE` | the machine's short name, for messages and run metadata |
| `OCEAN_RESULTS_ROOT` | **simulation output**: write under `$OCEAN_RESULTS_ROOT/<your repository>/` |
| `OCEAN_DATA_DIR` | downloaded input data (ECCO, EN4, ETOPO, ...; NumericalEarth uses it) |
| `OCEAN_JOB_LOGS` | inside a job (Slurm or `run_local.sh`): the folder of the job's log; put the other small files a job writes (timings, GPU-usage samples) there |
| `JULIA_DEPOT_PATH` | the shared depot: your project reuses the packages already installed |

plus Julia, the system MPI and CUDA. `JULIA_CUDA_MEMORY_POOL=none`, needed for fast GPU-to-GPU MPI
([drac.md](drac.md) step 7), is set by `ocean_setup` on the Alliance and by `tools/run_local.sh` on
pelee and rondeau. `OCEAN_RESULTS_ROOT` is `$SCRATCH/results` on the
Alliance clusters and `/mnt/autofs/bow.math/scratch/$USER/results` on pelee and rondeau (one folder
for both). Set any of these before `ocean_setup` to use another value.

**Scripts and files:**

| Path | What for |
| --- | --- |
| `setup/configure_mpi.sh <project>` | once per machine: your project uses the system MPI |
| `tools/check_env.sh <project>` | says what is wrong with the environment or your project |
| `src/drac_mpi.jl` | `include` it and call `drac_mpi_init()` before starting MPI ([drac.md](drac.md) step 7) |
| `jobs/submit_gpu.sh <your job script> <N>` | submits your job script on N GPUs with the cluster's Slurm options |
| `tools/run_local.sh` | the same on pelee and rondeau (no Slurm): free GPUs, background, log |
| `viz/` | the plotting environment: `julia --project=$OCEAN_HPC_ROOT/viz your_plot.jl` |

## What your repository does

1. **Its own `Project.toml` and `Manifest.toml`, without Makie** (plotting goes through `viz/`, so
   simulations never compile it). Commit both; `LocalPreferences.toml` goes in `.gitignore` (it holds
   this machine's MPI paths).
2. **Once per machine:** `ocean_setup`, then
   `bash $OCEAN_HPC_ROOT/setup/configure_mpi.sh .` and `bash $OCEAN_HPC_ROOT/tools/check_env.sh .`.
3. **Output under `$OCEAN_RESULTS_ROOT/<repository>/`**, never inside the repository.
4. **Job scripts source the environment and leave GPUs and memory to `submit_gpu.sh`** (template below).
5. **Say which version it was tested with** ("oceananigans-hpc v0.2.0") in its README.

## A job script

Copy this into your repository as, for example, `jobs/run.sh`:

```bash
#!/bin/bash
# One run of scripts/run.jl on N GPUs. Submit from the repository root, after ocean_setup:
#     bash $OCEAN_HPC_ROOT/jobs/submit_gpu.sh jobs/run.sh 4 --time=6:00:00 -- --config=my_preset
#SBATCH --job-name=run
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --output=%x_%j.out

cd "$SLURM_SUBMIT_DIR"
source "$OCEAN_HPC_ROOT/env/ocean_setup.sh"
set -eo pipefail          # after loading modules, as module commands can return harmless errors
julia --project=. -e 'using Pkg; Pkg.precompile()'
srun --cpu-bind=none julia --project=. scripts/run.jl "$@"
# other files the job writes go next to its log, e.g.:  nvidia-smi ... > "$OCEAN_JOB_LOGS/gpu_$SLURM_JOB_ID.csv"
```

- **No GPU, task or memory lines:** `submit_gpu.sh` adds `--nodes`, `--ntasks-per-node`,
  `--gpus-per-node` (never `--gpus-per-task`) and `--mem` for the cluster you are on, and checks
  Trillium's rules. Options after `--` reach the script as `"$@"`.
- **Logs** go to `logs/` in the folder you submit from; on Trillium to `$SCRATCH/<repository>/logs`
  (the repository's folder name without `.jl`, e.g. `$SCRATCH/BalancedFlows/logs`). Inside the job,
  `$OCEAN_JOB_LOGS` names that folder: write other small files the job makes there, not to the
  current folder.
- **Trillium:** submit from the repository as anywhere else; jobs cannot write to `/project`, and
  `submit_gpu.sh`, `OCEAN_JOB_LOGS` and `OCEAN_RESULTS_ROOT` all point to `$SCRATCH`. Precompile on
  the login node before submitting. `submit_gpu.sh` passes `OCEAN_HPC_ROOT` to the job, which
  Trillium's `sbatch` would otherwise not do (it starts jobs with a clean environment).
- **pelee and rondeau:** no job script; run
  `bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpus 4 scripts/run.jl --config=my_preset`.

## When oceananigans-hpc changes

Pull it on every machine (`git pull` in `$OCEAN_HPC_ROOT`), and rerun `setup/setup.sh` there if its
release notes say the packages changed. Your project's own Manifest is yours: upgrade it when you
choose, after the platform has been tested with the new versions ([ROADMAP.md](../ROADMAP.md),
Phase 4).

**Julia is the same version on every machine**: the `julia_version` of this repository's
`Manifest.toml` (1.10.10), from the module on the Alliance and from `setup/install_julia.sh` on
pelee and rondeau. Make your Manifest with that version, so instantiating it on another machine
does not rewrite it; `tools/check_env.sh .` warns when your Manifest or the running Julia differs.
When the platform moves to a new Julia, its release notes say so: then regenerate your Manifest
(`julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'`), rerun your tests and
commit it.

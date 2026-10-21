# Using the fluids group's GPU servers (pelee, rondeau)

pelee and rondeau are private servers of the Waterloo fluids group: 4× A100-SXM4-40GB each,
linked by NVLink, with a shared drive and **no Slurm**. Not everyone has access. This page is also
a worked example for any machine without a scheduler: copy `env/fluidsgpu.sh` and change its
MACHINE-SPECIFIC block.

## What is different from the Alliance

| | Alliance (Nibi, Fir, Rorqual) | pelee, rondeau |
| --- | --- | --- |
| Environment | `env/drac.sh` | `env/fluidsgpu.sh` |
| MPI | `openmpi/4.1.5` | `openmpi/4.1.7-with-cuda` (CUDA-aware, built for the group) |
| Julia | 1.10.10, our own install in `/project` (`setup/install_julia.sh`) | 1.10.10, our own install on the shared drive (`setup/install_julia.sh`) |
| Running | `sbatch` | `tools/run_local.sh` |
| GPUs | given by Slurm | shared: `run_local.sh` picks free ones |
| Internet | login nodes only | yes |

You source the same `env/ocean_setup.sh` on both; it picks the right file.

## One-time setup

pelee and rondeau share a drive, so set up once from either:

```bash
alias ocean_setup='source /path/to/oceananigans-hpc/env/ocean_setup.sh'   # in ~/.bashrc
cd /path/to/oceananigans-hpc
bash setup/install_julia.sh    # Julia 1.10.10 on the shared drive (the modules stop at 1.10.8)
ocean_setup                    # uses that julia
bash setup/setup.sh            # main environment and system MPI
bash setup/setup_viz.sh        # plotting environment
bash tools/check_env.sh        # should end with "All checks OK."
```

For your own project: `bash $OCEAN_HPC_ROOT/setup/configure_mpi.sh /path/to/project`.

`LocalPreferences.toml` holds this machine's MPI path, so a project folder used on both the
Alliance and pelee needs a separate clone on each (the usual case: the drives are different).
`check_env.sh` warns if a project's MPI settings come from another machine.

## Running

From your project folder, after `ocean_setup`:

```bash
bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpus 4 scripts/run.jl --resolution=4km    # 4 GPUs
bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpus 1 scripts/run.jl                     # 1 GPU
bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpus 0 --viz scripts/make_movies.jl       # plots
```

`run_local.sh` (all its options: `bash $OCEAN_HPC_ROOT/tools/run_local.sh --help`; the short forms
`-n`, `-g`, `-p`, `-j` of `--gpus`, `--gpu-ids`, `--project`, `--job-name` also work):

- picks GPUs with no running process (or exactly the ones given with `--gpu-ids 0,1`) and refuses to
  start if not enough are free, showing who is using them;
- with `--gpus 4`, starts 4 MPI ranks, each seeing only its own GPU, with
  `JULIA_CUDA_MEMORY_POOL=none` (needed by CUDA-aware MPI; the setup verified by the Gulf Stream
  code on pelee);
- runs in the background, immune to logout, with output in `logs/<name>_<date-time>.out`
  (`_2`, `_3`, ... added when runs with the same name start in the same second);
- prints the process ID: `kill <pid>` stops the run and all its ranks.

`--dry-run` shows what would run without starting anything.

**Starting several runs at once: give each its own GPUs with `--gpu-ids`.** A GPU counts as free when no
process is running on it, and a Julia run only shows up on its GPU once CUDA starts, tens of
seconds after launch. Runs started within that time can pick the same GPU, and then share it
(slower, or out of memory). So for runs started together, for example from a test script:

```bash
bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpu-ids 0,1 --gpus 2 --job-name case_a scripts/run.jl --config=a &
bash $OCEAN_HPC_ROOT/tools/run_local.sh --gpu-ids 2,3 --gpus 2 --job-name case_b scripts/run.jl --config=b &
```

Runs started by hand a minute or more apart are fine without `-g`.

## Checks

Before the first multi-GPU run, run the checks on 2 GPUs (then 4), from the repository root:

```bash
cd $OCEAN_HPC_ROOT
for c in single_mpi cuda_aware_mpi distributed_vs_serial output; do
    bash tools/run_local.sh --wait --gpus 2 --job-name check_$c checks/$c.jl || break
done
grep -h "PASS\|FAIL" logs/check_*.out      # one PASS per check
```

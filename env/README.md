# Environment files

`ocean_setup.sh` is the only file you source directly. It detects the machine and sources one of:

| File | Machines | Scheduler |
| --- | --- | --- |
| `drac.sh` | Alliance clusters: Nibi, Fir, Rorqual, Trillium (GPU) | Slurm |
| `fluidsgpu.sh` | pelee, rondeau (Waterloo fluids group servers; shared drive) | none |

`fluidsgpu.sh` is specific to our group's servers, which not everyone can use. It is kept here as
a worked example for any machine without Slurm and with locally built modules.

## What every environment file must provide

Scripts in `setup/`, `jobs/` and `tools/` rely only on these, so a new machine needs nothing else:

| Variable | Meaning |
| --- | --- |
| `OCEAN_HPC_ROOT` | root of this repository (also exported as `OCEANANIGANS_DRAC_ROOT`, the old name, until v0.3.0) |
| `OCEAN_MACHINE` | short machine name, for messages and logs |
| `OCEAN_MPI_ROOT` | installation prefix of the system OpenMPI (contains `lib/libmpi.so`) |
| `OPAL_PREFIX` | set to `$OCEAN_MPI_ROOT` (see `src/drac_mpi.jl`) |
| `JULIA_DEPOT_PATH` | one depot, set after loading modules |
| `JULIA_NUM_THREADS` | default 1 |
| `JULIA_NUM_PRECOMPILE_TASKS` | default 2, so precompiling doesn't hit login-node thread limits |
| `OCEAN_DATA_DIR` | downloaded input data (ECCO, EN4, ETOPO, ...); also `NUMERICALEARTH_DATA_DIRECTORY` |
| `OCEAN_RESULTS_ROOT` | simulation output: `$SCRATCH/results` on the Alliance, `/mnt/autofs/bow.math/scratch/$USER/results` on pelee/rondeau; repositories write under `$OCEAN_RESULTS_ROOT/<repository>/` |

plus the modules that put `julia` and the system `mpiexec` on `PATH`.

Optional: `OCEAN_JOB_DIR`, where scripts write logs and results from inside jobs when the
repository is not writable from compute nodes (set on Trillium to `$SCRATCH/oceananigans-drac`;
default: the repository).

Ocean data: `OCEAN_DATA_DIR` (default: `ocean_data` next to the Julia depot), also exported as
`NUMERICALEARTH_DATA_DIRECTORY`, so NumericalEarth stores and finds ECCO, EN4, ETOPO, JRA55… there.

The two are separate on purpose. `OCEAN_DATA_DIR` holds input data that is downloaded once on a
login node and kept (so it sits next to the depot, never on a purged scratch file system), and jobs
only read it. `OCEAN_JOB_DIR` is where this repository's own jobs write their logs and test results; it is set
only where jobs cannot write to the repository (Trillium, on `$SCRATCH`). `OCEAN_RESULTS_ROOT` is
for simulation output, from any repository: see [docs/simulation_repos.md](../docs/simulation_repos.md).
Values set before sourcing `ocean_setup.sh` are kept.

#!/bin/bash
# Environment for Oceananigans on Alliance clusters (Nibi, Fir, Rorqual, Trillium GPU). Source it, don't run it:
#
#     source env/drac.sh
#
# Used by setup/setup.sh and by every job script, so that setup and jobs always see the
# same modules and the same Julia depot.

# Remember the depot chosen by the user (first entry only) BEFORE loading modules. The julia
# module appends empty entries to JULIA_DEPOT_PATH ("...::"), and Julia expands empty entries
# to its default depots, including ~/.julia in $HOME. Setting the depot cleanly afterwards
# keeps Julia to exactly one depot.
_drac_depot="${JULIA_DEPOT_PATH%%:*}"

module --force purge                 # some modules are "sticky" and stay loaded: that is normal
module load StdEnv/2023
module load gcc/12.3
module load openmpi/4.1.5
module load cuda/12.6
module load julia/1.10.10

export OCEAN_MACHINE="${CC_CLUSTER:-alliance}"

# Trillium (SciNet): $HOME and $PROJECT are read-only on compute nodes, so jobs must write (and
# be submitted from) $SCRATCH. Scripts that write from jobs put their logs and results under
# OCEAN_JOB_DIR when it is set (default: this repository). Not for the Julia depot: $SCRATCH is
# purged, and the depot only needs to be written from the login node.
if [[ "$CC_CLUSTER" == trillium ]]; then
    export OCEAN_JOB_DIR="${OCEAN_JOB_DIR:-$SCRATCH/oceananigans-hpc}"
fi

# Inside a job, use the compute node's own Slurm commands. sbatch --export=ALL (as our submit
# scripts use) copies the login shell's PATH and SLURM_HOME into the job. When a cluster upgrades
# Slurm on the compute nodes before the login nodes, srun from the login node's Slurm cannot load
# the node's plugins and every job fails in seconds ("Incompatible Slurm plugin ... auth_munge":
# Nibi, Oct 15-17, 2026, login nodes on 25.11.7p, GPU nodes on 25.11.8/25.11.9). srun must come
# from the same Slurm installation as the plugins it loads, so take the node's Slurm folder from
# PluginDir in its slurm.conf, and put that folder's bin first. No versions are written here.
if [[ -n "$SLURM_JOB_ID" && -r "${SLURM_CONF:-/etc/slurm/slurm.conf}" ]]; then
    _drac_plugins="$(grep -m1 -i '^ *PluginDir *=' "${SLURM_CONF:-/etc/slurm/slurm.conf}" | cut -d= -f2 | cut -d: -f1 | tr -d ' ')"
    _drac_slurm="${_drac_plugins%/lib/slurm}"; _drac_slurm="${_drac_slurm%/lib64/slurm}"
    if [[ -n "$_drac_plugins" && "$_drac_slurm" != "$_drac_plugins" && -x "$_drac_slurm/bin/srun" ]]; then
        export SLURM_HOME="$_drac_slurm"
        export PATH="$_drac_slurm/bin:$PATH"
    fi
    unset _drac_plugins _drac_slurm
fi

# The system OpenMPI (the setup scripts use this, not the Alliance-specific $EBROOTOPENMPI).
export OCEAN_MPI_ROOT="$EBROOTOPENMPI"

# OpenMPI_jll >= 4.1.10 keeps OPAL_PREFIX if it is already set. Pointing it at the system
# OpenMPI makes MPI.Init() load the system plugins even when NetCDF loads OpenMPI_jll.
export OPAL_PREFIX="$OCEAN_MPI_ROOT"

# Root of this repository (the folder containing env/), for scripts that need it.
export OCEAN_HPC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Old name (until v0.4.0), for simulation repositories and ~/.bashrc lines written before the
# repository was renamed (Oceananigans-DRAC -> oceananigans-hpc, Oct 2026). Use OCEAN_HPC_ROOT.
export OCEANANIGANS_DRAC_ROOT="$OCEAN_HPC_ROOT"

# Julia depot: where packages and compiled code are stored (about 2 GB). Not on $SCRATCH,
# which is purged after 60 days without access. Choose another (e.g. project space) by
# setting JULIA_DEPOT_PATH before sourcing this file.
export JULIA_DEPOT_PATH="${_drac_depot:-$HOME/julia_depot}"

unset _drac_depot

# Trillium jobs: the depot is read-only on compute nodes, and Julia 1.10 fails when it can't update
# the timestamp of a precompiled file it loads ("SystemError: futimes: Permission denied"). So jobs
# use a writable copy of the compiled files on $SCRATCH, listed first; packages and artifacts are
# still read from the project depot. Julia tries the most recently modified cache first, and the
# copies are newer. Only new or updated files are copied (a few seconds once the copy exists).
# Nothing in this copy needs keeping: if $SCRATCH is purged it is simply made again.
if [[ "$CC_CLUSTER" == trillium && -n "$SLURM_JOB_ID" && "$JULIA_DEPOT_PATH" != *:* ]]; then
    _drac_rw="$SCRATCH/julia_depot_jobs"
    mkdir -p "$_drac_rw/compiled"
    if [[ -d "$JULIA_DEPOT_PATH/compiled" ]]; then
        # cp without -p: the copies get the current time, so they are newer than the originals;
        # -u: copy only files that are missing or older than the original (updated packages)
        ( flock 9; cp -ru "$JULIA_DEPOT_PATH/compiled/." "$_drac_rw/compiled/" ) 9>"$_drac_rw/.lock"
    fi
    export JULIA_DEPOT_PATH="$_drac_rw:$JULIA_DEPOT_PATH"
    unset _drac_rw
fi

# Inside a job: where its log is (the same rule submit_gpu.sh used), so a job can put the other
# files it writes next to it. On Trillium that is on $SCRATCH, the only place jobs can write.
if [[ -n "$SLURM_JOB_ID" && -n "$SLURM_SUBMIT_DIR" ]]; then
    source "$OCEAN_HPC_ROOT/jobs/gpu_request.sh"
    export OCEAN_JOB_LOGS="$(job_logs_dir "$SLURM_SUBMIT_DIR")"
    mkdir -p "$OCEAN_JOB_LOGS" 2>/dev/null || true
fi

# One CPU thread per rank is enough when the work is on the GPU.
export JULIA_NUM_THREADS="${JULIA_NUM_THREADS:-1}"

# Precompile at most 2 packages at a time. The default (one per core) starts so many linker
# threads that login nodes refuse them ("Resource temporarily unavailable").
export JULIA_NUM_PRECOMPILE_TASKS="${JULIA_NUM_PRECOMPILE_TASKS:-2}"

# CUDA-aware MPI between GPUs needs CUDA.jl's memory pool off. GPU arrays from the pool can't be
# shared with another process through CUDA IPC, so UCX silently copies them through the host instead
# of GPU to GPU: on Nibi (2 x H100, NVLink) MPI_Alltoall ran at 15 GB/s with the pool and 294 GB/s
# without it (Oct 15, 2026). tools/run_local.sh sets the same on pelee/rondeau. NCCL is unaffected.
export JULIA_CUDA_MEMORY_POOL="${JULIA_CUDA_MEMORY_POOL:-none}"

echo "oceananigans-hpc environment (${CC_CLUSTER:-unknown cluster}): repo=$OCEAN_HPC_ROOT, depot=$JULIA_DEPOT_PATH"





# Ocean data (ECCO, EN4, ETOPO, ...): a folder next to the Julia depot unless OCEAN_DATA_DIR is
# already set. NumericalEarth reads and downloads its datasets there. Download on a login node
# (compute nodes have no internet, and on Trillium they can't write to /project).
export OCEAN_DATA_DIR="${OCEAN_DATA_DIR:-$(dirname "${JULIA_DEPOT_PATH##*:}")/ocean_data}"
export NUMERICALEARTH_DATA_DIRECTORY="${NUMERICALEARTH_DATA_DIRECTORY:-$OCEAN_DATA_DIR}"
echo "  ocean data: $OCEAN_DATA_DIR"

# Simulation output: one folder per machine family, the same shape everywhere (/scratch/$USER/results).
# Each simulation repository writes under $OCEAN_RESULTS_ROOT/<repository>/ (docs/simulation_repos.md).
# On $SCRATCH because Trillium jobs can write nowhere else; $SCRATCH is purged after 60 days without
# access, so copy what you keep. A value set before sourcing this file wins. Not created here.
export OCEAN_RESULTS_ROOT="${OCEAN_RESULTS_ROOT:-${SCRATCH:-$HOME/scratch}/results}"
echo "  results: $OCEAN_RESULTS_ROOT"

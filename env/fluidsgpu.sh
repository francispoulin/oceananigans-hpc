#!/bin/bash
# Environment for Oceananigans on the Waterloo fluids group's GPU servers, pelee and rondeau
# (4x A100 each, shared drive, no Slurm). Don't run or source it directly; source
# env/ocean_setup.sh, which sources this file on pelee and rondeau:
#
#     source env/ocean_setup.sh
#
# Not everyone has access to these machines. The file is also an example for any server
# without Slurm and with locally built modules: change the block marked MACHINE-SPECIFIC.

_fluids_depot="${JULIA_DEPOT_PATH%%:*}"      # remember the user's depot before loading modules

# ---- MACHINE-SPECIFIC ------------------------------------------------------------------
# In non-interactive shells (setup scripts, run_local.sh) the `module` function may not be
# defined; define it the way the group's ~/.profile does.
if ! type module >/dev/null 2>&1; then
    module() { eval "$(/opt/uwsys/lmod/stable/libexec/lmod bash "$@")"; }
fi

# No `module purge`: it could remove the hidden .StdEnv module. Loading a module replaces any
# other loaded version of it. cuda/12.3.2 explicitly: the default cuda is 13.3.1, but the
# CUDA-aware OpenMPI is used with 12.3.2.
module load cuda/12.3.2
module load openmpi/4.1.7-with-cuda          # CUDA-aware OpenMPI built for the group

# Julia comes from env/julia.sh (below): our own install of Manifest.toml's julia_version. Until it
# is installed, the newest module here, julia/1.10.8 (the modules stop there).
_fluids_julia_module="julia/1.10.8"

# Default depot if JULIA_DEPOT_PATH is not set before sourcing: on the shared bow.math drive
# (same on pelee and rondeau, and keeps the large depot off /u), else $HOME.
if [[ -d "/mnt/autofs/bow.math/scratch/$USER" ]]; then
    _fluids_default_depot="/mnt/autofs/bow.math/scratch/$USER/julia_depot"
else
    _fluids_default_depot="$HOME/julia_depot"
fi
# ----------------------------------------------------------------------------------------

export OCEAN_MACHINE="$(hostname -s)"

# The system OpenMPI prefix. Derived from mpiexec on PATH, so it works whether or not the
# module sets a variable for it.
if command -v mpiexec >/dev/null 2>&1; then
    export OCEAN_MPI_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v mpiexec)")")")"
else
    echo "fluidsgpu.sh: mpiexec not found; is the openmpi module loaded?" >&2
    unset OCEAN_MPI_ROOT
fi
export OPAL_PREFIX="$OCEAN_MPI_ROOT"

export OCEAN_HPC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JULIA_DEPOT_PATH="${_fluids_depot:-$_fluids_default_depot}"
export JULIA_NUM_THREADS="${JULIA_NUM_THREADS:-1}"
export JULIA_NUM_PRECOMPILE_TASKS="${JULIA_NUM_PRECOMPILE_TASKS:-2}"

unset _fluids_depot _fluids_default_depot

# Julia on PATH (env/julia.sh): $OCEAN_SOFTWARE_DIR/julia-<version>, by default in a folder "software"
# next to the depot (on the shared drive, the same for pelee and rondeau).
_ocean_julia_module="$_fluids_julia_module"
source "$OCEAN_HPC_ROOT/env/julia.sh"
unset _fluids_julia_module

echo "oceananigans-hpc environment ($OCEAN_MACHINE): repo=$OCEAN_HPC_ROOT, depot=$JULIA_DEPOT_PATH"

# Ocean data (ECCO, EN4, ETOPO, ...): a folder next to the Julia depot unless OCEAN_DATA_DIR is
# already set. NumericalEarth reads and downloads its datasets there. Download on a login node
# (compute nodes have no internet, and on Trillium they can't write to /project).
export OCEAN_DATA_DIR="${OCEAN_DATA_DIR:-$(dirname "${JULIA_DEPOT_PATH##*:}")/ocean_data}"
export NUMERICALEARTH_DATA_DIRECTORY="${NUMERICALEARTH_DATA_DIRECTORY:-$OCEAN_DATA_DIR}"
echo "  ocean data: $OCEAN_DATA_DIR"

# Simulation output: on the shared bow.math drive, so pelee and rondeau see the same folder, with the
# same shape as on the Alliance (.../scratch/$USER/results). Each simulation repository writes under
# $OCEAN_RESULTS_ROOT/<repository>/ (docs/simulation_repos.md). A value set before sourcing wins.
if [[ -d "/mnt/autofs/bow.math/scratch/$USER" ]]; then
    export OCEAN_RESULTS_ROOT="${OCEAN_RESULTS_ROOT:-/mnt/autofs/bow.math/scratch/$USER/results}"
else
    export OCEAN_RESULTS_ROOT="${OCEAN_RESULTS_ROOT:-$HOME/results}"
fi
echo "  results: $OCEAN_RESULTS_ROOT"

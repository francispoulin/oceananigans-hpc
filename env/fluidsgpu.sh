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

# Julia: the same version as on the Alliance clusters, the one the platform's Manifest.toml was
# made with (its julia_version). The modules here stop at 1.10.8, so it is installed by hand once
# on the shared drive with setup/install_julia.sh. Without it, the julia/1.10.8 module, with a warning.
_fluids_julia_v="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../Manifest.toml")"
if [[ -z "${OCEAN_SOFTWARE_DIR:-}" ]]; then
    if [[ -d "/mnt/autofs/bow.math/scratch/$USER" ]]; then OCEAN_SOFTWARE_DIR="/mnt/autofs/bow.math/scratch/$USER/software"
    else OCEAN_SOFTWARE_DIR="$HOME/software"; fi
fi
export OCEAN_SOFTWARE_DIR
if [[ -x "$OCEAN_SOFTWARE_DIR/julia-$_fluids_julia_v/bin/julia" ]]; then
    module unload julia 2>/dev/null || true  # a julia module loaded earlier would not matter, but keep PATH clear
    export PATH="$OCEAN_SOFTWARE_DIR/julia-$_fluids_julia_v/bin:$PATH"
else
    module load julia/1.10.8
    echo "fluidsgpu.sh: Julia $_fluids_julia_v is not installed in $OCEAN_SOFTWARE_DIR; using the julia/1.10.8 module." >&2
    echo "              Install it once with: bash setup/install_julia.sh" >&2
fi
unset _fluids_julia_v

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

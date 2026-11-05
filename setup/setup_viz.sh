#!/bin/bash
# One-time setup of the plotting environment viz/ (CairoMakie + NCDatasets), on any machine.
# Needs internet, so on the Alliance run it on a LOGIN node. From anywhere:
#
#     bash /path/to/oceananigans-hpc/setup/setup_viz.sh
#
# viz/ is separate from the main (simulation) environment, so simulations never load Makie and
# the tested simulation Manifest stays unchanged. It holds no Oceananigans and no MPI: plotting
# scripts read the NetCDF output directly. Use it from any project folder:
#
#     julia --project=$OCEAN_HPC_ROOT/viz scripts/make_movies.jl
#
# To add a package for plotting:  julia --project=$OCEAN_HPC_ROOT/viz -e 'using Pkg; Pkg.add("X")'
# and commit viz/Project.toml and viz/Manifest.toml.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env/ocean_setup.sh"
set -eo pipefail          # after loading modules, as module commands can return harmless errors

echo "== 1. Install viz packages (exact versions if viz/Manifest.toml exists)"
julia --project="$ROOT/viz" -e 'using Pkg; Pkg.instantiate()'

echo "== 2. Precompile (JULIA_NUM_PRECOMPILE_TASKS=$JULIA_NUM_PRECOMPILE_TASKS)"
julia --project="$ROOT/viz" -e 'using Pkg; Pkg.precompile()'

echo
echo "Done. A warning 'Circular dependency detected ... CairoMakie' can appear (it did with Julia 1.10):"
echo "CairoMakie is then compiled the first time a script loads it (several minutes, once)."
echo "Do that first load in a compute job or salloc, not on a login node:"
echo "    julia --project=$ROOT/viz -e 'using CairoMakie, NCDatasets; println(\"viz OK\")'"
if ! git -C "$ROOT" ls-files --error-unmatch viz/Manifest.toml >/dev/null 2>&1; then
    echo "viz/Manifest.toml is new: commit it so other machines get the same versions."
fi

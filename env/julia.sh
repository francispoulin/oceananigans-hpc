#!/bin/bash
# Julia for every machine: the official release that this repository's Manifest.toml was made with
# (its julia_version), installed once per machine by setup/install_julia.sh. Not run or sourced by
# hand: env/drac.sh and env/fluidsgpu.sh source it after setting JULIA_DEPOT_PATH, as in
#
#     source "$OCEAN_HPC_ROOT/env/julia.sh"
#
# Sets OCEAN_JULIA_VERSION (from Manifest.toml) and OCEAN_SOFTWARE_DIR (where Julia is installed; a
# value set before sourcing wins; default: a folder "software" next to the Julia depot, e.g.
# /project/<group>/<user>/software on the Alliance, /mnt/autofs/bow.math/scratch/<user>/software
# on pelee/rondeau), and puts $OCEAN_SOFTWARE_DIR/julia-<version>/bin first on PATH.
# Not installed yet: loads the machine's julia module instead (the calling file sets
# _ocean_julia_module), with a warning saying how to install it. Every machine then runs the same
# binary, and a Julia upgrade is a new Manifest plus install_julia.sh, not a wait for a module.

_ojl_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCEAN_JULIA_VERSION="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$_ojl_root/Manifest.toml")"
export OCEAN_JULIA_VERSION

# Next to the depot: its last entry (on Trillium jobs the first entry is a copy on $SCRATCH).
_ojl_depot="${JULIA_DEPOT_PATH##*:}"
export OCEAN_SOFTWARE_DIR="${OCEAN_SOFTWARE_DIR:-$(dirname "${_ojl_depot:-$HOME/julia_depot}")/software}"

if [[ -x "$OCEAN_SOFTWARE_DIR/julia-$OCEAN_JULIA_VERSION/bin/julia" ]]; then
    module unload julia 2>/dev/null || true          # a julia module loaded earlier would only confuse PATH
    export PATH="$OCEAN_SOFTWARE_DIR/julia-$OCEAN_JULIA_VERSION/bin:$PATH"
else
    # The module appends empty entries to JULIA_DEPOT_PATH (they mean "also ~/.julia"): keep ours.
    _ojl_keep="$JULIA_DEPOT_PATH"
    module load "${_ocean_julia_module:-julia/$OCEAN_JULIA_VERSION}"
    export JULIA_DEPOT_PATH="$_ojl_keep"
    echo "ocean_setup: Julia $OCEAN_JULIA_VERSION is not installed in $OCEAN_SOFTWARE_DIR; using the ${_ocean_julia_module:-julia/$OCEAN_JULIA_VERSION} module." >&2
    echo "             Install it once (login node): bash $_ojl_root/setup/install_julia.sh" >&2
    unset _ojl_keep
fi
unset _ojl_root _ojl_depot _ocean_julia_module

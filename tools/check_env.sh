#!/bin/bash
# Check the current environment and a Julia project, and say what looks wrong. Read-only.
# Run it in the shell you work in (after ocean_setup), from your project folder:
#
#     bash $OCEAN_HPC_ROOT/tools/check_env.sh            # project = current folder
#     bash $OCEAN_HPC_ROOT/tools/check_env.sh /path/to/project
#
# Handy alias:  alias check_env='bash $OCEAN_HPC_ROOT/tools/check_env.sh'

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
PROJECT="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "no such folder: $1"; exit 1; }
nwarn=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; nwarn=$((nwarn+1)); }
info() { printf '        %s\n' "$*"; }

echo "== Environment"
OCEAN_HPC_ROOT="${OCEAN_HPC_ROOT:-${OCEANANIGANS_DRAC_ROOT:-}}"   # old name: environments set up before the rename
if [[ -z "$OCEAN_HPC_ROOT" ]]; then
    warn "ocean_setup has not been sourced in this shell (OCEAN_HPC_ROOT is empty)."
    info "Run: source /path/to/oceananigans-hpc/env/ocean_setup.sh   (or your alias)"
    exit 1
fi
ok "machine ${OCEAN_MACHINE:-?}, repository $OCEAN_HPC_ROOT"

if command -v julia >/dev/null 2>&1; then
    jv="$(julia --startup-file=no -e 'print(VERSION)')"
    ok "julia: $jv ($(command -v julia))"
    # One Julia on every machine: the version the platform's Manifest was made with
    pv="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$OCEAN_HPC_ROOT/Manifest.toml" 2>/dev/null)"
    if [[ -n "$pv" && "$jv" != "$pv" ]]; then
        warn "julia $jv, but the platform uses $pv (every machine runs the same version)"
        if [[ "${OCEAN_MACHINE:-}" == pelee* || "${OCEAN_MACHINE:-}" == rondeau* ]]; then
            info "Install it once: bash \$OCEAN_HPC_ROOT/setup/install_julia.sh, then source ocean_setup again"
        else
            info "Source ocean_setup again; if that does not help, the julia module in env/ needs updating"
        fi
    fi
else
    warn "julia is not on PATH (module not loaded?)"; exit 1
fi

case "$JULIA_DEPOT_PATH" in
    "")      warn "JULIA_DEPOT_PATH is empty: Julia will use ~/.julia" ;;
    "$SCRATCH/julia_depot_jobs:"[!:]*)                  # Trillium job (env/drac.sh): intended
             ok "depot ${JULIA_DEPOT_PATH#*:} (job: compiled files copied to ${JULIA_DEPOT_PATH%%:*})" ;;
    *:*)     warn "JULIA_DEPOT_PATH has several or empty entries: '$JULIA_DEPOT_PATH'"
             info "Something changed it after ocean_setup (a module load?). Source ocean_setup again." ;;
    *)       [[ -d "$JULIA_DEPOT_PATH" ]] && ok "depot $JULIA_DEPOT_PATH" \
                                         || warn "depot $JULIA_DEPOT_PATH does not exist yet (fine before first setup)" ;;
esac

[[ -n "$JULIA_NUM_PRECOMPILE_TASKS" ]] && ok "JULIA_NUM_PRECOMPILE_TASKS=$JULIA_NUM_PRECOMPILE_TASKS" \
    || warn "JULIA_NUM_PRECOMPILE_TASKS not set: precompiling on a login node may crash"

if [[ -f "$OCEAN_MPI_ROOT/lib/libmpi.so" ]]; then
    ok "system OpenMPI $OCEAN_MPI_ROOT"
    [[ "$OPAL_PREFIX" == "$OCEAN_MPI_ROOT" ]] || warn "OPAL_PREFIX ($OPAL_PREFIX) differs from OCEAN_MPI_ROOT"
else
    warn "no libmpi.so under OCEAN_MPI_ROOT='$OCEAN_MPI_ROOT' (openmpi module not loaded?)"
fi

echo "== GPUs"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    busy="$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader 2>/dev/null | sort -u)"
    while IFS=', ' read -r idx uuid name; do
        if grep -q "$uuid" <<<"$busy"; then state="busy"; else state="free"; fi
        info "GPU $idx  $name  ($state)"
    done < <(nvidia-smi --query-gpu=index,uuid,name --format=csv,noheader)
else
    info "no GPUs visible (normal on a login node or CPU job)"
fi

echo "== Project $PROJECT"
julia --startup-file=no "$OCEAN_HPC_ROOT/tools/check_project.jl" "$PROJECT"
nwarn=$((nwarn + $?))

echo
if [[ $nwarn -eq 0 ]]; then echo "All checks OK."; else echo "$nwarn warning(s) above."; fi

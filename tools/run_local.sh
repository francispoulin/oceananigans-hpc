#!/bin/bash
# Run a Julia script in the background on a machine WITHOUT Slurm (pelee, rondeau): picks free
# GPUs, survives logout, and writes a log, like sbatch does on the Alliance. After ocean_setup,
# from your project folder:
#
#     bash $OCEAN_HPC_ROOT/tools/run_local.sh -n 4 scripts/run.jl --arg=1   # 4 GPUs, MPI
#     bash $OCEAN_HPC_ROOT/tools/run_local.sh -n 1 scripts/run.jl          # 1 GPU
#     bash $OCEAN_HPC_ROOT/tools/run_local.sh -n 0 --viz scripts/make_movies.jl  # CPU, viz
#
# Options:
#   -n N        number of GPUs (= MPI ranks when N > 1); 0 = CPU only. Default 1.
#   -g 0,2      use exactly these GPUs instead of picking free ones
#   -p DIR      Julia project (default: current folder); --viz = the viz environment
#   -j NAME     run name for the log file (default: script name)
#   --all-visible  with N > 1, every rank sees all N chosen GPUs and picks its own by local
#               rank (Oceananigans' Distributed(GPU()) does this), instead of seeing only its own.
#               Not needed for speed on pelee/rondeau: MPI uses NVLink either way
#               (benchmarks/alltoall_bandwidth.jl). Kept for testing other machines.
#   --wait      stay attached until the run ends (still logged); exit status = the run's
#   --dry-run   show what would run, start nothing
#
# Output goes to logs/<name>_<date-time>.out in the current folder. The command prints the
# process ID; stop the run with `kill <pid>` (stops all its ranks).
#
# With N > 1, each MPI rank sees only its own GPU (rank i -> i-th chosen GPU), and
# JULIA_CUDA_MEMORY_POOL=none is set for every GPU run. This is the setup that the Gulf Stream
# code verified on pelee (1 vs 4 GPUs agree to ~1e-11; jobs/gpu_wrapper.sh there): CUDA-aware
# MPI needs the memory pool off to pass GPU buffers between processes.
#
# Free = no compute process on it now. Two runs started in the same second can still collide;
# check with `nvidia-smi` if in doubt.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
OCEAN_HPC_ROOT="${OCEAN_HPC_ROOT:-${OCEANANIGANS_DRAC_ROOT:-}}"   # old name: environments set up before the rename
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"

ngpu=1; gpus=""; project="$PWD"; name=""; dry=0; wait_end=0; all_visible=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) ngpu="$2"; shift 2 ;;
        -g) gpus="$2"; shift 2 ;;
        -p) project="$(cd "$2" && pwd)"; shift 2 ;;
        --viz) project="$OCEAN_HPC_ROOT/viz"; shift ;;
        -j) name="$2"; shift 2 ;;
        --wait) wait_end=1; shift ;;
        --all-visible) all_visible=1; shift ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        -*) echo "unknown option $1 (try --help)"; exit 1 ;;
        *) break ;;
    esac
done
[[ $# -ge 1 ]] || { echo "usage: run_local.sh [-n N] [-g list] [-p dir|--viz] [-j name] script.jl [args...]"; exit 1; }
script="$1"; shift
[[ -f "$script" ]] || { echo "no such script: $script (run from your project folder)"; exit 1; }
[[ -f "$project/Project.toml" ]] || { echo "no Project.toml in $project"; exit 1; }

# ---- choose GPUs ----
if [[ "$ngpu" -gt 0 ]]; then
    command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found: no GPUs here? Use -n 0."; exit 1; }
    if [[ -z "$gpus" ]]; then
        busy="$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader | sort -u)"
        free=()
        while IFS=', ' read -r idx uuid; do
            grep -q "$uuid" <<<"$busy" || free+=("$idx")
        done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)
        if [[ ${#free[@]} -lt $ngpu ]]; then
            echo "Only ${#free[@]} free GPU(s) (${free[*]:-none}); $ngpu requested. In use:"
            nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader |
                while IFS=', ' read -r uuid pid mem; do
                    idx="$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader | grep "$uuid" | cut -d, -f1)"
                    echo "  GPU $idx: pid $pid, user $(ps -o user= -p "$pid" 2>/dev/null || echo ?), $mem"
                done
            exit 1
        fi
        gpus="$(IFS=,; echo "${free[*]:0:$ngpu}")"
    fi
    export CUDA_VISIBLE_DEVICES="$gpus"
    export JULIA_CUDA_MEMORY_POOL="${JULIA_CUDA_MEMORY_POOL:-none}"
else
    export CUDA_VISIBLE_DEVICES=""
fi

# ---- command ----
jl=(julia --project="$project" "$script" "$@")
if [[ "$ngpu" -gt 1 && $all_visible -eq 1 ]]; then
    # Every rank sees all chosen GPUs (CUDA_VISIBLE_DEVICES=$gpus); the program picks one per rank.
    cmd=(mpiexec -n "$ngpu" --bind-to none "${jl[@]}")
elif [[ "$ngpu" -gt 1 ]]; then
    # One GPU per rank, chosen from the list by Open MPI's node-local rank.
    export RUN_LOCAL_GPUS="$gpus"
    percpu='export CUDA_VISIBLE_DEVICES=$(cut -d, -f$((OMPI_COMM_WORLD_LOCAL_RANK + 1)) <<<"$RUN_LOCAL_GPUS"); exec "$@"'
    cmd=(mpiexec -n "$ngpu" --bind-to none bash -c "$percpu" _ "${jl[@]}")
else
    cmd=("${jl[@]}")
fi

name="${name:-$(basename "$script" .jl)}"
mkdir -p logs
log="logs/${name}_$(date +%Y%m%d-%H%M%S).out"
export OCEAN_JOB_LOGS="$PWD/logs"      # as in Slurm jobs (env/drac.sh): where this run's log is

echo "machine:  ${OCEAN_MACHINE:-$(hostname -s)}"
echo "GPUs:     ${CUDA_VISIBLE_DEVICES:-none (CPU)}"
echo "project:  $project"
echo "command:  ${cmd[*]}"
echo "log:      $log"
[[ $dry -eq 1 ]] && { echo "(dry run: nothing started)"; exit 0; }

{
    echo "# $(date '+%F %T') on ${OCEAN_MACHINE:-$(hostname -s)}, user $USER"
    echo "# GPUs ${CUDA_VISIBLE_DEVICES:-none} ($([[ $all_visible -eq 1 ]] && echo "all visible to every rank" || echo "one per rank if several")), JULIA_CUDA_MEMORY_POOL=${JULIA_CUDA_MEMORY_POOL:-default}"
    echo "# ${cmd[*]}"
} > "$log"

# setsid + nohup: own process group, immune to logout. `kill <pid>` stops the whole group.
setsid nohup bash -c 'trap "echo \"# \$(date \"+%F %T\") stopped by kill\"; trap - TERM; kill 0" TERM
                      "$@" & wait $!; status=$?
                      echo "# $(date "+%F %T") finished, exit status $status"' _ "${cmd[@]}" >> "$log" 2>&1 < /dev/null &
pid=$!
echo "started:  pid $pid"
if [[ $wait_end -eq 1 ]]; then
    wait "$pid" || true
    tail -n 1 "$log"
    grep -q "exit status 0$" "$log"; exit $?
fi
echo
echo "  follow:  tail -f $log"
echo "  stop:    kill $pid"

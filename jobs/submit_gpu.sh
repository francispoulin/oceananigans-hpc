#!/bin/bash
# Submit a GPU job script on N GPUs (one MPI rank per GPU), with the Slurm
# options right for the cluster: as few nodes as possible, --gpus-per-node equal to the ranks per
# node (every rank sees all of its node's GPUs; never --gpus-per-task, see jobs/gpu_request.sh),
# and --mem=0 when a node's GPUs are all used. The script can be this repository's or another
# repository's (docs/simulation_repos.md). From the folder you submit from, after ocean_setup:
#
#     bash jobs/submit_gpu.sh jobs/checks.sh 2                 # 2 GPUs on one node
#     bash jobs/submit_gpu.sh jobs/checks.sh 16                # Nibi: 2 nodes; Fir, Rorqual: 4 nodes
#     bash jobs/submit_gpu.sh jobs/benchmark.sh 8 --time=2:00:00 --export=ALL,SIZE=2880x1440x200
#     DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh 8        # print the sbatch command only
#     bash $OCEAN_HPC_ROOT/jobs/submit_gpu.sh jobs/run.sh 4 --time=6:00:00 -- --config=bgr_tanh
#                                                             # another repository's job script
#
# Arguments after the GPU count go to sbatch (and override the defaults); arguments after `--` go
# to the job script.
# Settings: GPUS_PER_NODE (default from the cluster: 8 on Nibi, 4 elsewhere), MEM (memory per node
# when the node is not full, default 64G), JOB_NAME (default <script>_<N>gpu).
# Above one node, N must be a multiple of the GPUs per node. Logs: logs/<name>_<jobid>.out in the
# folder you submit from; on Trillium, where jobs can't write there, $OCEAN_JOB_DIR/logs for this
# repository and $SCRATCH/<repository>/logs for another (job_logs_dir in jobs/gpu_request.sh).
# Inside the job, OCEAN_JOB_LOGS names that folder. The job also gets OCEAN_HPC_ROOT, even where
# sbatch starts jobs with a clean environment (Trillium).
#
# Without this wrapper (same result), e.g. 16 GPUs on Nibi:
#     sbatch --nodes=2 --ntasks-per-node=8 --gpus-per-node=h100:8 --mem=0 jobs/checks.sh

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
[[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 1 ]] || {
    echo "usage: bash jobs/submit_gpu.sh <job script> <number of GPUs> [sbatch options...] [-- script options...]"; exit 1; }
script="$1"; n="$2"; shift 2
sbatch_opts=(); script_opts=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -- ]]; then shift; script_opts=("$@"); break; fi
    sbatch_opts+=("$1"); shift
done
[[ -f "$script" ]] || { echo "no such job script: $script"; exit 1; }
[[ -n "$DRYRUN" ]] || command -v sbatch >/dev/null || {
    echo "no Slurm on this machine ($(hostname -s)): submit from an Alliance cluster;"
    echo "on pelee/rondeau use tools/run_local.sh instead (or DRYRUN=1 to see the sbatch command)"; exit 1; }

source "$OCEAN_HPC_ROOT/jobs/gpu_request.sh"
g="${GPUS_PER_NODE:-$(default_gpus_per_node)}"
if (( n <= g )); then
    nodes=1; per_node=$n
else
    (( n % g == 0 )) || { echo "$n GPUs: above one node, use a multiple of $g (GPUs per node here)"; exit 1; }
    nodes=$(( n / g )); per_node=$g
fi
gpu_request "$per_node" "${MEM:-64G}"
JOB_LOGS="$(job_logs_dir "$PWD")"          # next to the caller (this repository or another)
[[ -n "$DRYRUN" ]] || mkdir -p "$JOB_LOGS"

# The job must find this repository (it sources env/ocean_setup.sh): add OCEAN_HPC_ROOT to the
# caller's --export, or export everything plus it (the default elsewhere; Trillium's sbatch exports
# nothing unless told).
have_export=0
for i in "${!sbatch_opts[@]}"; do
    case "${sbatch_opts[$i]}" in
        --export=NONE) have_export=1 ;;
        --export=*) sbatch_opts[$i]="${sbatch_opts[$i]},OCEAN_HPC_ROOT=$OCEAN_HPC_ROOT"; have_export=1 ;;
    esac
done
(( have_export )) || sbatch_opts=(--export="ALL,OCEAN_HPC_ROOT=$OCEAN_HPC_ROOT" "${sbatch_opts[@]}")
name="${JOB_NAME:-$(basename "$script" .sh)_${n}gpu}"

cmd=(sbatch --job-name="$name" --nodes="$nodes" --ntasks-per-node="$per_node" "${GPU_OPTS[@]}"
     --output="$JOB_LOGS/%x_%j.out" "${sbatch_opts[@]}" "$script" "${script_opts[@]}")
echo "${cmd[*]}"
[[ -n "$DRYRUN" ]] || "${cmd[@]}"

#!/bin/bash
# Submit the MPI-vs-NCCL scaling set for the pressure solver (Fourier-tridiagonal) on any cluster:
# 1 GPU, 2 GPUs, then 1, 2 and 4 full nodes (GPUs per node from jobs/gpu_request.sh: 8 on Nibi,
# 4 elsewhere), each strong (512x512x256 total) and weak (512x512x256 per GPU), with MPI
# and with NCCL. From the repository root, on a login node, after ocean_setup and
# bash setup/setup_nccl_env.sh (once per cluster):
#
#     bash jobs/submit_poisson_scaling.sh                # all, up to 4 nodes (17 jobs)
#     MAXNODES=2 bash jobs/submit_poisson_scaling.sh     # up to 2 nodes (8 GPUs)
#     DRYRUN=1 bash jobs/submit_poisson_scaling.sh       # show the sbatch commands only
#
# Results, when the jobs have run:  grep -ah "^RESULT poisson" logs/p_*.out
# Every RESULT line must say finite=true and shared_gpu=false; p_std must agree between MPI and
# NCCL for the same grid.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
cd "$OCEAN_HPC_ROOT"
source jobs/gpu_request.sh
G="${GPUS_PER_NODE:-$(default_gpus_per_node)}"
MAXNODES="${MAXNODES:-4}"
SOLVER="${SOLVER:-FourierTridiagonal}"

submit() {   # name nodes tasks_per_node size comm
    gpu_request "$3" 64G
    local cmd=(sbatch --job-name="$1" --nodes="$2" --ntasks-per-node="$3" "${GPU_OPTS[@]}"
               --output="$JOB_LOGS/%x_%j.out" --export="ALL,SIZE=$4,COMM=$5,SOLVER=$SOLVER"
               jobs/benchmark_poisson.sh)
    if [[ -n "$DRYRUN" ]]; then echo "${cmd[*]}"; else "${cmd[@]}"; fi
}

submit p_1gpu 1 1 512x512x256 MPI
for comm in MPI NCCL; do
    for layout in "1 2" "1 $G" "2 $G" "4 $G"; do
        read -r nodes tasks <<<"$layout"
        (( nodes > MAXNODES )) && continue
        n=$(( nodes * tasks ))
        submit "p_strong_${comm}_${n}gpu" "$nodes" "$tasks" 512x512x256 "$comm"
        submit "p_weak_${comm}_${n}gpu"   "$nodes" "$tasks" "$(( 512 * n ))x512x256" "$comm"
    done
done
echo "Submitted. Check with: squeue -u \$USER;  results: grep -ah '^RESULT poisson' $JOB_LOGS/p_*.out"

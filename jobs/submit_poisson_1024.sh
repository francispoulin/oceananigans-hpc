#!/bin/bash
# Pressure solver alone at 1024^3 in Float32 (fits on ONE H100-80GB: ~38 GiB), MPI vs NCCL, on
# any cluster: 1, 2, 4 and 8 GPUs, on as few nodes as possible (the GPUs per node come from
# jobs/gpu_request.sh: 8 GPUs are one node on Nibi, two elsewhere).
# Strong scaling only (same 1024^3 grid on all). From the repository root, on a login node, after
# ocean_setup and bash setup/setup_nccl_env.sh (once per cluster):
#
#     bash jobs/submit_poisson_1024.sh                    # 7 jobs
#     MAXNODES=1 bash jobs/submit_poisson_1024.sh         # one node only (Fir: 1, 2, 4 GPUs; 5 jobs)
#     DRYRUN=1 bash jobs/submit_poisson_1024.sh        # show the sbatch commands only
#
# Results:  grep -ah "^RESULT poisson" logs/p1024_*.out   (Trillium: $OCEAN_JOB_DIR/logs/)
# Trillium: 2-GPU runs use a whole 4-GPU node (only 1 GPU or whole nodes can be requested there).
# Expected memory (from 512^3 on rondeau): ~38 GiB on 1 GPU, ~20 GiB per GPU on 2, ~11 on 4.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
cd "$OCEAN_HPC_ROOT"
source jobs/gpu_request.sh
G="${GPUS_PER_NODE:-$(default_gpus_per_node)}"
MAXNODES="${MAXNODES:-2}"
SIZE="${SIZE:-1024x1024x1024}"
FLOAT="${FLOAT:-Float32}"
SOLVER="${SOLVER:-FourierTridiagonal}"

submit() {   # name nodes tasks_per_node comm
    gpu_request "$3" 128G
    local cmd=(sbatch --job-name="$1" --nodes="$2" --ntasks-per-node="$3" "${GPU_OPTS[@]}"
               --output="$JOB_LOGS/%x_%j.out"
               --export="ALL,SIZE=$SIZE,COMM=$4,SOLVER=$SOLVER,FLOAT=$FLOAT"
               jobs/benchmark_poisson.sh)
    if [[ -n "$DRYRUN" ]]; then echo "${cmd[*]}"; else "${cmd[@]}"; fi
}

submit p1024_1gpu 1 1 MPI
for comm in MPI NCCL; do
    for n in 2 4 8; do
        nodes=$(( (n + G - 1) / G ))
        (( nodes > MAXNODES )) && continue
        submit "p1024_${comm}_${n}gpu" "$nodes" "$(( n / nodes ))" "$comm"
    done
done
echo "Submitted. Check with: squeue -u \$USER;  results: grep -ah '^RESULT poisson' $JOB_LOGS/p1024_*.out"

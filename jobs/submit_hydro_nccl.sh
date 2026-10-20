#!/bin/bash
# Submit the hydrostatic MPI-vs-NCCL comparison (Oceananigans benchmark suite, earth_ocean on a
# 1440x720x200 lat-lon grid, as in results/nibi_scaling.md) on any cluster: strong scaling on
# 1 GPU, then 1, 2 and 4 full nodes (GPUs per node from jobs/gpu_request.sh: 8 on Nibi, 4
# elsewhere), with MPI and with NCCL. From the repository root, on a login node, after setup/setup_benchmark_suite.sh:
#
#     DRYRUN=1 bash jobs/submit_hydro_nccl.sh     # show the sbatch commands
#     bash jobs/submit_hydro_nccl.sh              # 7 jobs; MAXNODES=2 stops at 8 GPUs
#
# Results (JSON, one record per rank) in $BENCH_DIR/results/; summarize with
#     python3 tools/summarize_benchmarks.py $BENCH_DIR/results/hyd_*.json
# Logs: logs/hyd_*.out

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
cd "$OCEAN_HPC_ROOT"
source jobs/gpu_request.sh
G="${GPUS_PER_NODE:-$(default_gpus_per_node)}"
MAXNODES="${MAXNODES:-4}"
SIZE="${SIZE:-1440x720x200}"
export BENCH_DIR="${BENCH_DIR:-$SCRATCH/software/Oceananigans.jl/benchmarking}"
[[ -f "$BENCH_DIR/run_benchmarks.jl" ]] || { echo "no suite in $BENCH_DIR: run setup/setup_benchmark_suite.sh"; exit 1; }
grep -q -- '"--comm"' "$BENCH_DIR/run_benchmarks.jl" || { echo "suite in $BENCH_DIR has no --comm option: run setup/setup_benchmark_suite.sh"; exit 1; }

submit() {   # name nodes tasks_per_node comm
    gpu_request "$3" 64G
    local exports="ALL,SIZE=$SIZE,BENCH_DIR=$BENCH_DIR"
    [[ -n "$4" ]] && exports="$exports,COMM=$4"
    local cmd=(sbatch --job-name="$1" --nodes="$2" --ntasks-per-node="$3" "${GPU_OPTS[@]}"
               --output="$JOB_LOGS/%x_%j.out" --export="$exports" jobs/benchmark.sh)
    if [[ -n "$DRYRUN" ]]; then echo "${cmd[*]}"; else "${cmd[@]}"; fi
}

submit hyd_1gpu 1 1 ""
for comm in MPI NCCL; do
    for nodes in 1 2 4; do
        (( nodes > MAXNODES )) && continue
        submit "hyd_${comm}_$(( nodes * G ))gpu" "$nodes" "$G" "$comm"
    done
done
echo "Submitted. squeue -u \$USER; then python3 tools/summarize_benchmarks.py $BENCH_DIR/results/hyd_*.json"

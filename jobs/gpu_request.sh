#!/bin/bash
# Slurm options for a GPU job with one MPI rank per GPU, for the submit_*.sh scripts (source it).
#
#     gpu_request <tasks per node> <memory when not a full node>   ->  sets the array GPU_OPTS
#
# Every rank sees ALL the GPUs of its node (--gpus-per-node), and Oceananigans' Distributed(GPU())
# picks one per rank by node-local rank. With --gpus-per-task, Slurm fences each rank off so it
# sees only its own GPU; CUDA-aware MPI then can't reach the other GPUs' memory directly and copies
# everything through the host (Nibi, Oct 15: 1024^3 transposes ~25 GB/s instead of NVLink speed),
# and NCCL fails (ncclUnhandledCudaError). The benchmarks print shared_gpu=true if two ranks ever
# pick the same GPU.
#
# Trillium: only 1 GPU or whole nodes (4 GPUs), no --mem; 2 ranks run on a whole 4-GPU node.
# Elsewhere (Nibi, Fir, Rorqual): h100 GPUs (not MIG slices), --mem=0 for a full node.
# GPUS_PER_NODE: 4 (Fir, Rorqual, Trillium) or 8 (Nibi); the default follows $CC_CLUSTER, so it
# only needs setting to override. (Oct 16: with the old default of 4, a 4-GPU job on Nibi asked
# for --mem=0 on half a node and sbatch refused it; 8-GPU jobs got --mem=<mem> instead of the node.)

# Short test jobs (tools/run_tests.sh: about 10 minutes) ask for 20 minutes, and on Trillium go to its
# debug partitions (1 hour at most): debug_full_node for whole nodes, debug for 1 GPU. The scheduler
# does not pick debug by itself: on Oct 21, 2026 a 30-minute test in compute_full_node was estimated
# to start the next afternoon, and the same job moved to debug_full_node (scontrol update) about a day
# earlier. The other clusters have no debug partition; their jobs are placed by requested time, and a
# short request fits more gaps in the schedule (backfill).
#
#     test_job_request <tasks per node>   ->  sets the array TEST_JOB_OPTS
test_job_request() {
    TEST_JOB_OPTS=( --time=0:20:00 )
    if [[ "$CC_CLUSTER" == trillium ]]; then
        if (( $1 == 1 )); then TEST_JOB_OPTS+=( --partition=debug ); else TEST_JOB_OPTS+=( --partition=debug_full_node ); fi
    fi
}

default_gpus_per_node() { [[ "$CC_CLUSTER" == nibi ]] && echo 8 || echo 4; }

gpu_request() {
    local tasks="$1" mem="$2" g="${GPUS_PER_NODE:-$(default_gpus_per_node)}"
    if [[ "$CC_CLUSTER" == trillium ]]; then
        GPU_OPTS=( --gpus-per-node="$(( tasks == 1 ? 1 : 4 ))" )
    else
        GPU_OPTS=( --gpus-per-node="h100:$tasks" )
        if (( tasks == g )); then GPU_OPTS+=( --mem=0 ); else GPU_OPTS+=( --mem="$mem" ); fi
    fi
}

# Where a job writes its log, from the folder it is submitted from. Used by submit_gpu.sh when
# submitting, and by env/drac.sh inside the job (as OCEAN_JOB_LOGS), so both agree: on Trillium the
# job's environment is not passed on from the submitting shell, so the job works it out again.
#   - this repository:    logs/ in it, or $OCEAN_JOB_DIR/logs where jobs can't write to it (Trillium)
#   - another repository: logs/ in it; on Trillium, where jobs can't write to /project,
#                         $SCRATCH/<repository>/logs (folder name of the git repository, minus .jl)
job_logs_dir() {   # <folder submitted from>
    local dir root name
    dir="$(cd "$1" 2>/dev/null && pwd -P)" || dir="$1"
    root="$(cd "${OCEAN_HPC_ROOT:-.}" 2>/dev/null && pwd -P)"
    if [[ "$dir" == "$root" || "$dir" == "$root"/* ]]; then
        echo "${OCEAN_JOB_DIR:-$root}/logs"
    elif [[ "$CC_CLUSTER" == trillium ]]; then
        name="$(basename "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")")"
        echo "$SCRATCH/${name%.jl}/logs"
    else
        echo "$dir/logs"
    fi
}

# This repository's own submit scripts write their logs here.
JOB_LOGS="$(job_logs_dir "${OCEAN_HPC_ROOT:-.}")"
mkdir -p "$JOB_LOGS"

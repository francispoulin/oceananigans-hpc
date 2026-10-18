#!/bin/bash
# Checks the Slurm options the submit scripts produce on each cluster, without Slurm or GPUs
# (DRYRUN=1 prints the sbatch commands). Runs on every pull request (.github/workflows/checks.yml)
# and anywhere with bash:  bash tests/ci/test_submit_scripts.sh
#
# Cluster facts tested: Nibi has 8 GPUs per node, Fir and Rorqual 4, Trillium 4 with only 1 GPU or
# whole nodes and no --mem; --mem=0 only for a full node; never --gpus-per-task.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OCEAN_HPC_ROOT="$ROOT"
export OCEAN_JOB_DIR; OCEAN_JOB_DIR="$(mktemp -d)"     # logs/ created by gpu_request.sh go here
cd "$ROOT" || exit 1
fails=0

# expect <cluster> <gpus> <must contain...>   (one submit_gpu.sh dry run)
expect() {
    local cluster="$1" n="$2"; shift 2
    local out; out="$(CC_CLUSTER="$cluster" DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh "$n" 2>&1)"
    local ok=1 want
    for want in "$@"; do
        if [[ "$want" == !* ]]; then [[ "$out" == *"${want#!}"* ]] && ok=0
        else [[ "$out" == *"$want"* ]] || ok=0; fi
    done
    [[ "$out" == *--gpus-per-task* ]] && ok=0
    report "$ok" "submit_gpu.sh on $cluster, $n GPUs" "$out"
}

# refuse <cluster> <gpus>   (must exit with an error)
refuse() {
    local out
    if out="$(CC_CLUSTER="$1" DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh "$2" 2>&1)"; then
        report 0 "submit_gpu.sh on $1 refuses $2 GPUs" "$out"
    else
        report 1 "submit_gpu.sh on $1 refuses $2 GPUs" "$out"
    fi
}

report() {   # ok name output
    if [[ "$1" == 1 ]]; then echo "PASS  $2"; else echo "FAIL  $2"; echo "      $3"; fails=$((fails + 1)); fi
}

expect nibi 1   --nodes=1 --ntasks-per-node=1 --gpus-per-node=h100:1 --mem=64G
expect nibi 4   --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=64G
expect nibi 8   --nodes=1 --ntasks-per-node=8 --gpus-per-node=h100:8 --mem=0
expect nibi 16  --nodes=2 --ntasks-per-node=8 --gpus-per-node=h100:8 --mem=0
expect fir 2    --nodes=1 --ntasks-per-node=2 --gpus-per-node=h100:2 --mem=64G
expect fir 4    --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0
expect fir 8    --nodes=2 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0
expect rorqual 16 --nodes=4 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0
expect trillium 1 --nodes=1 --ntasks-per-node=1 --gpus-per-node=1 '!--mem'
expect trillium 2 --nodes=1 --ntasks-per-node=2 --gpus-per-node=4 '!--mem'
expect trillium 8 --nodes=2 --ntasks-per-node=4 --gpus-per-node=4 '!--mem'
refuse fir 6
refuse nibi x

# The other submit scripts: no --gpus-per-task, and the 8-GPU pressure solve on one node on Nibi
for cluster in nibi fir rorqual trillium; do
    for script in jobs/submit_poisson_1024.sh jobs/submit_poisson_scaling.sh; do
        out="$(CC_CLUSTER="$cluster" DRYRUN=1 bash "$script" 2>&1)"; ok=1
        [[ $? -eq 0 && "$out" == *"sbatch "* && "$out" != *--gpus-per-task* ]] || ok=0
        [[ "$cluster" == trillium && "$out" == *--mem* ]] && ok=0
        report "$ok" "$(basename "$script") on $cluster" "$(head -2 <<<"$out")"
    done
done
out="$(CC_CLUSTER=nibi DRYRUN=1 bash jobs/submit_poisson_1024.sh 2>&1 | grep p1024_MPI_8gpu)"
[[ "$out" == *--nodes=1* && "$out" == *--mem=0* ]] && ok=1 || ok=0
report "$ok" "submit_poisson_1024.sh: 8 GPUs on one Nibi node" "$out"

# Another repository's job script: sbatch options before the script, script options after `--`,
# logs in the folder submitted from (where jobs can write; on Trillium $OCEAN_JOB_DIR/logs)
ext="$(mktemp -d)"; mkdir -p "$ext/jobs"; printf '#!/bin/bash\n' > "$ext/jobs/run.sh"
out="$(cd "$ext" && env -u OCEAN_JOB_DIR CC_CLUSTER=nibi DRYRUN=1 bash "$ROOT/jobs/submit_gpu.sh" jobs/run.sh 4 --time=6:00:00 -- --config=x --stop_days=3 2>&1)"
[[ "$out" == *"--output=$ext/logs/%x_%j.out --time=6:00:00 jobs/run.sh --config=x --stop_days=3" && ! -d "$ext/logs" ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh: another repository's script, options after --, logs next to it" "$out"
out="$(cd "$ext" && CC_CLUSTER=trillium DRYRUN=1 bash "$ROOT/jobs/submit_gpu.sh" jobs/run.sh 4 -- --config=x 2>&1)"
[[ "$out" == *"--output=$OCEAN_JOB_DIR/logs/%x_%j.out jobs/run.sh --config=x" ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh on trillium: logs in \$OCEAN_JOB_DIR/logs" "$out"
rm -rf "$ext"

# tools/run_tests.sh: the platform-test job, Slurm options from jobs/gpu_request.sh on every cluster
rt() {   # cluster gpus must-contain...
    local cluster="$1" g="$2"; shift 2
    local out; out="$(CC_CLUSTER="$cluster" DRYRUN=1 bash tools/run_tests.sh --gpus "$g" 2>&1)"; local ok=1 want
    for want in "$@"; do
        if [[ "$want" == !* ]]; then [[ "$out" == *"${want#!}"* ]] && ok=0
        else [[ "$out" == *"$want"* ]] || ok=0; fi
    done
    [[ "$out" == *--gpus-per-task* ]] && ok=0
    report "$ok" "run_tests.sh on $cluster, GPUs \"$g\"" "$out"
}
rt nibi "1 4"     --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=128G
rt fir "1 4"      --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0
rt rorqual "1 4"  --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0
rt trillium "1 4" --nodes=1 --ntasks-per-node=4 --gpus-per-node=4 --time=0:30:00 '!--mem'
rt trillium "1"   --nodes=1 --ntasks-per-node=1 --gpus-per-node=1 '!--mem'
out="$(CC_CLUSTER=fir DRYRUN=1 bash tools/run_tests.sh --gpus "1 8" 2>&1)" && ok=0 || ok=1
[[ "$out" == *"at most 4 GPUs"* ]] || ok=0
report "$ok" "run_tests.sh on fir refuses 8 GPUs (one node only)" "$out"

rm -rf "$OCEAN_JOB_DIR"
echo "$fails failure(s)"
exit $(( fails > 0 ))

#!/bin/bash
# Checks the Slurm options the submit scripts produce on each cluster, without Slurm or GPUs,
# and that tools/run_local.sh gives runs started together separate logs
# (DRYRUN=1 prints the sbatch commands). Runs on every pull request (.github/workflows/checks.yml)
# and anywhere with bash:  bash tests/ci/test_submit_scripts.sh
#
# Cluster facts tested: Nibi has 8 GPUs per node, Fir and Rorqual 4, Trillium 4 with only 1 GPU or
# whole nodes and no --mem; --mem=0 only for a full node; never --gpus-per-task; a job warns when
# its ranks have fewer than 2 CPU cores each.

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
# OCEAN_HPC_ROOT exported to the job, logs next to the caller; on Trillium in $SCRATCH/<repository>/logs
ext="$(mktemp -d)/MySims.jl"; mkdir -p "$ext/jobs"; printf '#!/bin/bash\n' > "$ext/jobs/run.sh"
out="$(cd "$ext" && env -u OCEAN_JOB_DIR CC_CLUSTER=nibi DRYRUN=1 bash "$ROOT/jobs/submit_gpu.sh" jobs/run.sh 4 --time=6:00:00 -- --config=x --stop_days=3 2>&1)"
[[ "$out" == *"--output=$ext/logs/%x_%j.out --export=ALL,OCEAN_HPC_ROOT=$ROOT --time=6:00:00 jobs/run.sh --config=x --stop_days=3" && ! -d "$ext/logs" ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh: another repository's script, options after --, OCEAN_HPC_ROOT exported" "$out"
out="$(cd "$ext" && CC_CLUSTER=trillium SCRATCH=/scratch/u DRYRUN=1 bash "$ROOT/jobs/submit_gpu.sh" jobs/run.sh 4 -- --config=x 2>&1)"
[[ "$out" == *"--output=/scratch/u/MySims/logs/%x_%j.out --export=ALL,OCEAN_HPC_ROOT=$ROOT jobs/run.sh --config=x" ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh on trillium: another repository's logs in \$SCRATCH/<repository>/logs" "$out"
out="$(CC_CLUSTER=trillium DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh 4 2>&1)"
[[ "$out" == *"--output=$OCEAN_JOB_DIR/logs/%x_%j.out"* ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh on trillium: this repository's logs in \$OCEAN_JOB_DIR/logs" "$out"
out="$(CC_CLUSTER=fir DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh 2 --export=ALL,SIZE=64 2>&1)"
[[ "$out" == *"--export=ALL,SIZE=64,OCEAN_HPC_ROOT=$ROOT jobs/checks.sh"* && "$out" != *"--export=ALL,OCEAN_HPC_ROOT"* ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh: OCEAN_HPC_ROOT added to the caller's --export" "$out"
out="$(CC_CLUSTER=fir DRYRUN=1 bash jobs/submit_gpu.sh jobs/checks.sh 2 --export=NONE 2>&1)"
[[ "$out" == *"--export=NONE jobs/checks.sh"* ]] && ok=1 || ok=0
report "$ok" "submit_gpu.sh: --export=NONE left alone" "$out"
# inside the job (env/drac.sh): the same folder, worked out from SLURM_SUBMIT_DIR
inj="$(cd "$ext" && CC_CLUSTER=trillium SCRATCH=/scratch/u bash -c 'source "$OCEAN_HPC_ROOT/jobs/gpu_request.sh" 2>/dev/null; job_logs_dir "$PWD"')"
[[ "$inj" == /scratch/u/MySims/logs ]] && ok=1 || ok=0
report "$ok" "job_logs_dir in the job agrees with submit_gpu.sh (trillium)" "$inj"
rm -rf "$(dirname "$ext")"

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
rt nibi "1 4"     --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=128G --time=0:20:00 '!--partition'
rt fir "1 4"      --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0 --time=0:20:00 '!--partition'
rt rorqual "1 4"  --nodes=1 --ntasks-per-node=4 --gpus-per-node=h100:4 --mem=0 --time=0:20:00 '!--partition'
rt trillium "1 4" --nodes=1 --ntasks-per-node=4 --gpus-per-node=4 --time=0:20:00 --partition=debug_full_node '!--mem'
rt trillium "1"   --nodes=1 --ntasks-per-node=1 --gpus-per-node=1 --time=0:20:00 '--partition=debug ' '!--mem'
out="$(CC_CLUSTER=fir DRYRUN=1 bash tools/run_tests.sh --gpus "1 8" 2>&1)" && ok=0 || ok=1
[[ "$out" == *"at most 4 GPUs"* ]] || ok=0
report "$ok" "run_tests.sh on fir refuses 8 GPUs (one node only)" "$out"

# check_cores_per_rank (jobs/gpu_request.sh, called by env/drac.sh in every job)
ccr() { env "$@" bash -c 'source jobs/gpu_request.sh; check_cores_per_rank' 2>&1; }
out="$(ccr SLURM_JOB_ID=1 SLURM_PROCID=0 SLURM_CPUS_ON_NODE=4 SLURM_NTASKS_PER_NODE=4)"
[[ "$out" == *"WARNING: 4 CPU core(s) for 4 rank(s)"* ]] && ok=1 || ok=0
report "$ok" "check_cores_per_rank: warns with 1 core per rank" "$out"
out="$(ccr SLURM_JOB_ID=1 SLURM_PROCID=0 SLURM_CPUS_ON_NODE=32 SLURM_TASKS_PER_NODE='4(x2)')"
[[ -z "$out" ]] && ok=1 || ok=0
report "$ok" "check_cores_per_rank: quiet with 8 cores per rank (ranks from SLURM_TASKS_PER_NODE)" "$out"
out="$(ccr SLURM_JOB_ID=1 SLURM_PROCID=3 SLURM_CPUS_ON_NODE=4 SLURM_NTASKS_PER_NODE=4)"
[[ -z "$out" ]] && ok=1 || ok=0
report "$ok" "check_cores_per_rank: only rank 0 warns" "$out"
out="$(ccr SLURM_CPUS_ON_NODE=4 SLURM_NTASKS_PER_NODE=4)"
[[ -z "$out" ]] && ok=1 || ok=0
report "$ok" "check_cores_per_rank: quiet outside a job" "$out"

# tools/run_local.sh (pelee/rondeau): runs started together with the same name get separate logs
lt="$(mktemp -d)"; mkdir -p "$lt/bin" "$lt/proj"; touch "$lt/proj/Project.toml" "$lt/proj/run.jl"
printf '#!/bin/bash\necho "julia $*"\n' > "$lt/bin/julia"; chmod +x "$lt/bin/julia"
for i in 1 2 3; do
    (cd "$lt/proj" && PATH="$lt/bin:$PATH" bash "$ROOT/tools/run_local.sh" -n 0 -j same --wait run.jl --i=$i >/dev/null 2>&1) &
done; wait
out="$(cat "$lt"/proj/logs/same_*.out 2>/dev/null)"
[[ $(ls "$lt"/proj/logs/same_*.out 2>/dev/null | wc -l) -eq 3 && "$out" == *--i=1* && "$out" == *--i=2* && "$out" == *--i=3* ]] && ok=1 || ok=0
report "$ok" "run_local.sh: three runs started together with the same name get three logs" "$(ls "$lt"/proj/logs 2>&1)"

# run_local.sh: long and short option names give the same command (the log line has the time, so it
# is left out); `--name=value` works; mistakes stop with a message
printf '#!/bin/bash\nexit 0\n' > "$lt/bin/nvidia-smi"; chmod +x "$lt/bin/nvidia-smi"
mkdir -p "$lt/other"; touch "$lt/other/Project.toml"
rl() { (cd "$lt/proj" && PATH="$lt/bin:$PATH" bash "$ROOT/tools/run_local.sh" --dry-run "$@" 2>&1) | grep -v '^log:'; }
short="$(rl -n 2 -g 1,3 -p ../other -j myrun run.jl --x=1)"
for long in "--gpus 2 --gpu-ids 1,3 --project ../other --job-name myrun" \
            "--gpus=2 --gpu-ids=1,3 --project=../other --job-name=myrun"; do
    # shellcheck disable=SC2086  # $long is several options on purpose
    out="$(rl $long run.jl --x=1)"
    [[ "$out" == "$short" && "$out" == *"GPUs:     1,3"* && "$out" == *"mpiexec -n 2"* && "$out" == *"--x=1"* ]] && ok=1 || ok=0
    report "$ok" "run_local.sh: $long gives the same command as -n 2 -g 1,3 -p ../other -j myrun" "$out
--- short form:
$short"
done
out="$(rl -n 2 -g 1,3 --prefix "nsys profile -o logs/p_rank%q{OMPI_COMM_WORLD_RANK}" run.jl --x=1)"
[[ "$out" == *'exec "$@" _ nsys profile -o logs/p_rank%q{OMPI_COMM_WORLD_RANK} julia --project='*'run.jl --x=1'* ]] && ok=1 || ok=0
report "$ok" "run_local.sh: --prefix puts the command before each rank's julia" "$out"
for bad in "--gpus" "--gpus two" "--gpus --wait" "--wait=1" "--gpu 2"; do
    # shellcheck disable=SC2086
    out="$(cd "$lt/proj" && PATH="$lt/bin:$PATH" bash "$ROOT/tools/run_local.sh" --dry-run $bad run.jl 2>&1)" && ok=0 || ok=1
    [[ "$out" == *"(dry run"* ]] && ok=0
    report "$ok" "run_local.sh refuses '$bad'" "$out"
done
rm -rf "$lt"

rm -rf "$OCEAN_JOB_DIR"
echo "$fails failure(s)"
exit $(( fails > 0 ))

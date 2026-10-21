#!/bin/bash
# Platform sanity tests on this machine, with ONE command. After ocean_setup, from anywhere:
#
#     bash $OCEAN_HPC_ROOT/tools/run_tests.sh                  # 1 and 4 GPUs (~10 min)
#     bash $OCEAN_HPC_ROOT/tools/run_tests.sh --gpus "1 2"      # if only 2 GPUs are free
#     bash $OCEAN_HPC_ROOT/tools/run_tests.sh --gpus "1 2 4"    # everything (~16 min)
#
# 4 GPUs cover everything 2 GPUs do (with 4 ranks some have neighbours on both sides), so 2 is not
# run by default. Most of the time is compiling each model once per process, not running it.
#
# What runs, in order (each step is one process; tests/platform.jl lists its tests in detail):
#
#   check_env        environment and this repository's project (warnings, not failures)
#   platform, 1 GPU  load, grids, single_mpi, output, hydro_channel, hydro_box, checkpoint,
#                    nh_fft, nh_ft (saves the 1-GPU reference fields)
#   platform, 4 GPUs load, single_mpi, cuda_aware, halo, output, hydro_channel, hydro_box,
#                    checkpoint, nh_fft, nh_ft (compared with the 1-GPU reference)
#                    (and the same on 2 GPUs if asked for)
#   viz              viz environment: NetCDF, PNG and MP4 with CairoMakie (CPU)
#
# These test the platform only (environment, MPI, CUDA, Oceananigans and other libraries, viz);
# simulation repositories test their own physics. Proof of function, not performance: small grids,
# 10-30 steps. About 4 min for 1 GPU, 6 min for 2 or 4 GPUs (mostly compiling).
#
# pelee/rondeau: one step after another via tools/run_local.sh; a step that needs more GPUs than are
# free is SKIPPED. Alliance: packages are precompiled here (login node), then one Slurm job runs
# everything (the summary appears when it ends). Trillium: whole-GPU scheduling (1 or 4 GPUs), and
# jobs can't write to $HOME/$PROJECT, so logs and the summary go to $OCEAN_JOB_DIR (on $SCRATCH);
# copy the summary into results/tests/ to commit it (the job prints the command).
# Output: results/tests/<machine>_<date-time>.md (publish it with tools/publish_summary.sh: the
# record of what was tested, with which versions), and one log per step in logs/. To test a branch
# without switching the clone: tools/test_branch.sh.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
ROOT="$OCEAN_HPC_ROOT"
OUT="${OCEAN_JOB_DIR:-$ROOT}"          # where logs and results are written (Trillium: $SCRATCH)
mkdir -p "$OUT/logs" "$OUT/results/tests"
cd "$OUT" || exit 1

gpus="1 4"; in_job=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpus) gpus="$2"; shift 2 ;;
        --in-job) in_job=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option $1 (try --help)"; exit 1 ;;
    esac
done
maxgpu=$(tr ' ' '\n' <<<"$gpus" | sort -n | tail -1)

# ---- Alliance: submit everything as one job, then stop ----
# DRYRUN=1 prints the sbatch command without precompiling or submitting (tests/ci uses it).
slurm=0
[[ -n "$CC_CLUSTER" ]] && { command -v sbatch >/dev/null || [[ -n "$DRYRUN" ]]; } && slurm=1
if [[ $slurm -eq 1 && $in_job -eq 0 && -z "$SLURM_JOB_ID" ]]; then
    # The GPU, memory and node rules of each cluster live in jobs/gpu_request.sh only.
    source "$ROOT/jobs/gpu_request.sh"
    pernode=$(default_gpus_per_node)
    (( maxgpu > pernode )) && { echo "$CC_CLUSTER: at most $pernode GPUs (one node) for the tests"; exit 1; }
    gpu_request "$maxgpu" 128G
    test_job_request "$maxgpu"           # 20 minutes; Trillium: its debug partitions (start much sooner)
    res=(--ntasks-per-node="$maxgpu" "${GPU_OPTS[@]}" "${TEST_JOB_OPTS[@]}")
    # Trillium allocates whole GPUs with their cores; elsewhere 4 cores per rank.
    [[ "$CC_CLUSTER" == trillium ]] || res+=(--cpus-per-task=4)
    cmd=(sbatch --job-name=tests --nodes=1 "${res[@]}" --output="$OUT/logs/tests_%j.out"
         --export=ALL "$ROOT/tools/run_tests.sh" --in-job --gpus "$gpus")
    if [[ -n "$DRYRUN" ]]; then echo "${cmd[*]}"; exit 0; fi
    # Precompile on the login node: compute nodes may not be able to write to the depot (Trillium).
    echo "Precompiling (login node; quick if nothing changed)..."
    { julia --project="$ROOT" -e 'using Pkg; Pkg.precompile()' &&
      julia --project="$ROOT/viz" -e 'using Pkg; Pkg.precompile()'; } \
        > "logs/tests_precompile_$(date +%Y%m%d-%H%M).out" 2>&1 || echo "WARNING: precompile failed (see logs/)"
    "${cmd[@]}"
    echo "Submitted. When it ends: cat $OUT/logs/tests_<jobid>.out; summary in $OUT/results/tests/."
    exit 0
fi
if [[ $in_job -eq 1 ]]; then
    source "$ROOT/env/ocean_setup.sh" >/dev/null
    OUT="${OCEAN_JOB_DIR:-$ROOT}"
    cd "$OUT" || exit 1
fi

# ---- run ----
mkdir -p logs results/tests
stamp=$(date +%Y%m%d-%H%M)
machine="${OCEAN_MACHINE:-$(hostname -s)}"
summary="results/tests/${machine}_${stamp}.md"
export TEST_REF_DIR="$OUT/logs/tests_ref_${stamp}"      # 1-GPU reference fields for this run
rows=(); npass=0; nfail=0; nskip=0

record() {   # test gpus result seconds detail log
    rows+=("| $1 | $2 | $3 | $4 | $5 | \`$6\` |")
    printf '%-15s %-4s %-5s %5ss  %s\n' "$1" "$2" "$3" "$4" "$5"
    case "$3" in PASS) npass=$((npass+1)) ;; FAIL) nfail=$((nfail+1)) ;; *) nskip=$((nskip+1)) ;; esac
}

# Run one step: name gpus project script. Sets $status and $log.
run_step() {
    local name=$1 n=$2 proj=$3 script=$4
    log="logs/tests_${name}_${stamp}.out"
    if [[ $slurm -eq 1 ]]; then
        if [[ $n -eq 0 ]]; then julia --project="$proj" "$script" > "$log" 2>&1
        else srun --exact --ntasks="$n" --cpu-bind=none julia --project="$proj" "$script" > "$log" 2>&1; fi
        status=$?
    else
        local out runlog
        out=$(bash "$ROOT/tools/run_local.sh" --wait --gpus "$n" --project "$proj" --job-name "tests_${name}" "$script" 2>&1)
        status=$?
        runlog=$(sed -n 's/^log: *//p' <<<"$out")
        if [[ -n "$runlog" && -f "$runlog" ]]; then mv "$runlog" "$log"; else echo "$out" > "$log"; fi
        if [[ $status -ne 0 ]] && grep -q "free GPU" <<<"$out"; then status=99; fi   # GPUs busy
    fi
}

echo "Platform tests on $machine, $(date '+%F %T'), GPUs: $gpus"

# check_env (warnings are reported, not failures)
log="logs/tests_check_env_${stamp}.out"
bash "$ROOT/tools/check_env.sh" "$ROOT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$log"
nw=$(grep -c "WARN" "$log")
if [[ $nw -eq 0 ]]; then record check_env - PASS 0 "all checks OK" "$log"
else record check_env - WARN 0 "$nw warning(s): $(grep WARN "$log" | head -1 | sed 's/.*WARN *//' | cut -c1-80)" "$log"; fi

# precompile both environments once (not timed); on Slurm this was done on the login node
if [[ $slurm -eq 0 ]]; then
    { julia --project="$ROOT" -e 'using Pkg; Pkg.precompile()'; julia --project="$ROOT/viz" -e 'using Pkg; Pkg.precompile()'; } \
        > "logs/tests_precompile_${stamp}.out" 2>&1
fi

for n in $gpus; do
    start=$(date +%s)
    run_step "platform_${n}gpu" "$n" "$ROOT" "$ROOT/tests/platform.jl"
    if [[ $status -eq 99 ]]; then
        record "(platform)" "$n" SKIP 0 "GPUs busy: $(grep -o 'Only [0-9]* free GPU(s)' "$log" | head -1)" "$log"
        continue
    fi
    found=0
    while read -r _ tname tstatus tsecs tdetail; do
        found=1
        record "$tname" "$n" "$tstatus" "$tsecs" "$(cut -c1-100 <<<"$tdetail" | tr '|' '/')" "$log"
    done < <(grep "^TEST " "$log")
    if [[ $found -eq 0 || ( $status -ne 0 && -z "$(grep '^SUMMARY' "$log")" ) ]]; then
        record "(platform)" "$n" FAIL $(( $(date +%s) - start )) \
               "$(grep -E 'ERROR|Error|error' "$log" | tail -1 | cut -c1-100 | tr '|' '/')" "$log"
    fi
    echo "                     (platform on $n GPU(s): $(( $(date +%s) - start )) s in total)"
done

start=$(date +%s)
run_step viz 0 "$ROOT/viz" "$ROOT/tests/viz.jl"
secs=$(( $(date +%s) - start ))
detail=$(grep -E "PASS|FAIL|ERROR" "$log" | tail -1 | cut -c1-100 | tr '|' '/')
if [[ $status -eq 0 ]]; then record viz CPU PASS "$secs" "$detail" "$log"; else record viz CPU FAIL "$secs" "$detail" "$log"; fi

{
    echo "# Platform tests on $machine, $(date '+%F %T')"
    echo
    echo "oceananigans-hpc $(git -C "$ROOT" describe --tags --always 2>/dev/null) ($(git -C "$ROOT" log -1 --format='%h %s')). GPUs: $gpus."
    echo "**$npass passed, $nfail failed, $nskip skipped or warnings.**"
    echo
    echo "| Test | GPUs | Result | Seconds | Detail | Log |"
    echo "| --- | --- | --- | --- | --- | --- |"
    printf '%s\n' "${rows[@]}"
    echo
    echo '```'
    grep -hE "^(julia|Oceananigans|CUDA|MPI|NCDatasets|JLD2|OpenMPI_jll|GPU) " logs/tests_platform_*gpu_"${stamp}".out 2>/dev/null | sort -u
    echo '```'
} > "$summary"

echo
echo "$npass passed, $nfail failed, $nskip skipped/warnings. Summary: $OUT/$summary"
if [[ "$OUT" != "$ROOT" ]]; then
    echo "To publish it, from a login node: bash $ROOT/tools/publish_summary.sh $OUT/$summary"
fi
[[ $nfail -eq 0 ]]

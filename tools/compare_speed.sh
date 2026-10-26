#!/bin/bash
# The speed of an upgrade (ROADMAP.md, Phase 4, step 4): the pressure-solver benchmark
# (benchmarks/poisson_solver.jl) in two worktrees, one after the other on the same GPUs, compared in
# one table. On pelee/rondeau, after ocean_setup, from the clone:
#
#     bash tools/compare_speed.sh                     # the clone (A) vs <clone>-candidate (B): 1024³, Float32, 4 GPUs, MPI
#     bash tools/compare_speed.sh --comm NCCL         # the same with NCCL (needs envs/nccl in both worktrees)
#     bash tools/compare_speed.sh --b-script FILE.jl  # B runs FILE.jl instead of the benchmark (an experiment)
#     bash tools/compare_speed.sh --profile           # also profile both (Nsight Systems): GPU time per kernel, A vs B
#     bash tools/compare_speed.sh --report A.out B.out   # only compare two finished runs (their logs)
#
# Runs in the background and survives logout (like tools/run_local.sh); prints the log to follow.
# Waits for free GPUs (up to 60 minutes) before each run. Options (also --name=value):
#   --a DIR, --b DIR    the two worktrees (default: this clone, and <clone>-candidate)
#   --gpus N            GPUs = MPI ranks (default 4)
#   --size NxxNyxNz     global grid (default 1024x1024x1024)
#   --float T           Float32 or Float64 (default Float32)
#   --comm MPI|NCCL     transposes over MPI or NCCL (default MPI)
#   --b-script FILE     B runs FILE (it includes the benchmark after changing something) instead
#   --tolerance PCT     B slower than A by more than this is flagged (default 5)
#   --profile           run both under nsys (3 solves after the timing; needs nsys, e.g. module
#                       load cuda/12.3.2 on pelee/rondeau) and add the tables of rank 0: GPU time per
#                       kernel, per memory operation and per CUDA API call, per solve, A vs B, largest
#                       differences first; "GPU busy" against the time per solve shows waiting
#   --profile-report PA PB   only those tables, from the CSV files of two earlier profiles
#                       (prefixes, e.g. logs/speed_profile_<date>/A and .../B)
#   --wait              stay attached until both runs end
# Result: a table (time per solve, median, transposes, the rest, GPU memory, p_std) with B/A, the
# versions of Oceananigans and Julia in each, and a verdict; printed and saved as
# results/tests/speed_<machine>_<date>.md in B. Exit status 0 if B is within the tolerance and p_std
# agrees (relative difference below 1e-6, a correctness check), 1 otherwise.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    common="$(cd "$here" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)"
CLONE="${common:+$(dirname "$common")}"
args0=("$@")

A="$CLONE"; B="${CLONE:+$CLONE-candidate}"; n=4; size=1024x1024x1024; float=Float32; comm=MPI
bscript=""; tol=5; wait_end=0; report_only=0; logs=(); profile=0; preport=0
RUN_LOCAL="${COMPARE_SPEED_RUN_LOCAL:-$here/run_local.sh}"     # this script's own (tests replace it)
while [[ $# -gt 0 ]]; do
    a="$1"; v=""
    [[ "$a" == --*=* ]] && { v="${a#*=}"; a="${a%%=*}"; set -- "$a" "$v" "${@:2}"; }
    case "$a" in
        --a) A="$2"; shift 2 ;;
        --b) B="$2"; shift 2 ;;
        --gpus) n="$2"; shift 2 ;;
        --size) size="$2"; shift 2 ;;
        --float) float="$2"; shift 2 ;;
        --comm) comm="$2"; shift 2 ;;
        --b-script) bscript="$2"; shift 2 ;;
        --tolerance) tol="$2"; shift 2 ;;
        --wait) wait_end=1; shift ;;
        --report) report_only=1; shift ;;
        --profile) profile=1; shift ;;
        --profile-report) preport=1; shift ;;
        -*) echo "unknown option '$1' (try --help)"; exit 1 ;;
        *) logs+=("$1"); shift ;;
    esac
done

# ---------------------------------------------------------------- comparing two logs
field() {   # field <log> <name>: from the last "RESULT poisson" line of the log
    grep -ah '^RESULT poisson' "$1" | tail -1 | grep -oE " $2=(\"[^\"]*\"|[^ ]*)" | head -1 | sed "s/^ $2=//; s/\"//g"
}
versions() {   # versions <worktree>: "Oceananigans x.y.z, Julia a.b.c (commit)"
    local m="$1/Manifest.toml"
    [[ -f "$m" ]] || { echo "(no Manifest.toml)"; return; }
    local o j c
    o="$(awk '/^\[\[deps.Oceananigans\]\]/{f=1} f && /^version = /{gsub(/"/,"",$3); print $3; exit}' "$m")"
    j="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$m")"
    c="$(git -C "$1" describe --tags --always --dirty 2>/dev/null)"
    echo "Oceananigans ${o:-?}, Julia ${j:-?}${c:+ ($c)}"
}
compare() {   # compare <logA> <logB> [worktreeA worktreeB]: the table on stdout; status 0 = same speed and answer
    local la="$1" lb="$2" k
    for k in "$la" "$lb"; do
        [[ -n "$(field "$k" t_solve_min_ms)" ]] || { echo "No RESULT poisson line in $k (did the run fail? see the log)"; return 1; }
    done
    echo "# Speed comparison on ${OCEAN_MACHINE:-$(hostname -s)}, $(date '+%F %H:%M')"
    echo
    echo "Benchmark: \`benchmarks/poisson_solver.jl\`, $(field "$lb" solver), $(field "$lb" size), $(field "$lb" float), $(field "$lb" gpus) GPU(s), $(field "$lb" comm); $(field "$lb" gpu)"
    echo
    echo "- **A:** ${3:-$la}${3:+: $(versions "$3")}"
    echo "- **B:** ${4:-$lb}${4:+: $(versions "$4")}"
    echo "- Logs: \`$la\`, \`$lb\`"
    echo
    awk -v tol="$tol" \
        -v a1="$(field "$la" t_solve_min_ms)" -v b1="$(field "$lb" t_solve_min_ms)" \
        -v a2="$(field "$la" t_solve_median_ms)" -v b2="$(field "$lb" t_solve_median_ms)" \
        -v a3="$(field "$la" t_transposes_ms)" -v b3="$(field "$lb" t_transposes_ms)" \
        -v a5="$(field "$la" mem_GiB)" -v b5="$(field "$lb" mem_GiB)" \
        -v a6="$(field "$la" p_std)" -v b6="$(field "$lb" p_std)" \
        -v fa="$(field "$la" finite)" -v fb="$(field "$lb" finite)" '
    function row(name, a, b) { printf "| %s | %.1f | %.1f | %.3f |\n", name, a, b, (a > 0 ? b / a : 0) }
    BEGIN {
        print "| | A | B | B/A |"; print "| --- | --- | --- | --- |"
        row("time per solve, fastest window (ms)", a1, b1)
        row("time per solve, median (ms)", a2, b2)
        row("of which transposes (ms)", a3, b3)
        row("the rest: FFTs, tridiagonal, source term (ms)", a1 - a3, b1 - b3)
        printf "| GPU memory per GPU (GiB) | %.2f | %.2f | %.3f |\n", a5, b5, (a5 > 0 ? b5 / a5 : 0)
        d = (a6 != 0) ? (b6 - a6) / a6 : 1; if (d < 0) d = -d
        printf "| p_std (must agree) | %.12e | %.12e | rel. diff. %.1e |\n", a6, b6, d
        slower = 100 * (b1 / a1 - 1)
        same = (d < 1e-6 && fa == "true" && fb == "true")
        fast = (slower <= tol)
        print ""
        printf "**%s: B is %.1f%% %s than A (tolerance %g%%); p_std %s.**\n",
               (same && fast) ? "OK" : "CHECK", (slower < 0 ? -slower : slower),
               (slower < 0 ? "faster" : "slower"), tol,
               same ? sprintf("agrees (%.1e)", d) : "DIFFERS or not finite: a correctness problem"
        exit !(same && fast)
    }'
}

profile_table() {   # profile_table <prefix A> <prefix B> [t_solve A] [t_solve B]: markdown on stdout
    python3 - "$@" <<'PY'
import csv, glob, re, sys
pa, pb = sys.argv[1], sys.argv[2]
ts = [float(x) for x in sys.argv[3:5]] if len(sys.argv) >= 5 else None
NSOLVES = 3                                  # benchmarks/poisson_solver.jl --profile=true

def short(name):                             # kernel names without types and Julia's numbering
    n = re.split(r"[(<]", name.strip(), maxsplit=1)[0]
    return re.sub(r"_\d+$", "", n)[:70] or name[:70]

def load(prefix, kinds):
    files = [f for k in kinds for f in sorted(glob.glob(prefix + "*" + k + "*.csv"))]
    if not files:
        return None
    rows = list(csv.reader(open(files[0], newline="")))
    head = next((i for i, r in enumerate(rows) if any(c.startswith("Total Time") for c in r)), None)
    if head is None:
        return {}
    h = rows[head]
    ti = next(j for j, c in enumerate(h) if c.startswith("Total Time"))
    ci = next((j for j, c in enumerate(h) if c in ("Instances", "Count", "Num Calls", "Calls")), None)
    ni = next((j for j, c in enumerate(h) if c in ("Name", "Operation")), len(h) - 1)
    out = {}
    for r in rows[head + 1:]:
        if len(r) <= max(ti, ni) or not r[ti].strip():
            continue
        a = out.setdefault(short(r[ni]), [0.0, 0])
        a[0] += float(r[ti]) / 1e6 / NSOLVES                       # ms per solve
        a[1] += int(float(r[ci])) // NSOLVES if ci is not None else 0
    return out

sections = [("GPU kernels", ["cuda_gpu_kern_sum", "gpukernsum"]),
            ("GPU memory operations", ["cuda_gpu_mem_time_sum", "gpumemtimesum"]),
            ("CUDA API calls on the CPU (waiting for the GPU, allocations, launches)", ["cuda_api_sum", "cudaapisum"])]
busy = {}
print("## Profile, rank 0, per solve (Nsight Systems, %d solves)\n" % NSOLVES)
for title, kinds in sections:
    A, B = load(pa, kinds), load(pb, kinds)
    if A is None or B is None:
        print("%s: no CSV file for %s\n" % (title, pa if A is None else pb))
        continue
    names = sorted(set(A) | set(B), key=lambda k: -abs(B.get(k, [0, 0])[0] - A.get(k, [0, 0])[0]))
    ta, tb = sum(v[0] for v in A.values()), sum(v[0] for v in B.values())
    if title != sections[2][0]:
        busy[title] = (ta, tb)
    print("### %s\n" % title)
    print("| | A (ms) | B (ms) | B − A (ms) | calls A | calls B |")
    print("| --- | --- | --- | --- | --- | --- |")
    for k in names[:15]:
        a, b = A.get(k, [0.0, 0]), B.get(k, [0.0, 0])
        print("| `%s` | %.2f | %.2f | %+.2f | %d | %d |" % (k.replace("|", "/"), a[0], b[0], b[0] - a[0], a[1], b[1]))
    if len(names) > 15:
        print("| (%d more) | | | | | |" % (len(names) - 15))
    print("| **total** | **%.2f** | **%.2f** | **%+.2f** | | |\n" % (ta, tb, tb - ta))
if ts and busy:
    ga, gb = (sum(v[i] for v in busy.values()) for i in (0, 1))
    print("**GPU busy (kernels + memory operations) per solve: A %.1f of %.1f ms, B %.1f of %.1f ms.** "
          "Busy well below the time per solve means the GPU waits (for MPI, the CPU, a synchronization); "
          "above it, operations overlap (e.g. copies between GPUs during kernels)." % (ga, ts[0], gb, ts[1]))
PY
}

if [[ $preport -eq 1 ]]; then
    [[ ${#logs[@]} -eq 2 ]] || { echo "--profile-report needs two prefixes: --profile-report DIR/A DIR/B"; exit 1; }
    profile_table "${logs[0]}" "${logs[1]}"; exit $?
fi
if [[ $report_only -eq 1 ]]; then
    [[ ${#logs[@]} -eq 2 ]] || { echo "--report needs two logs: --report A.out B.out"; exit 1; }
    for f in "${logs[@]}"; do [[ -f "$f" ]] || { echo "no such log: $f"; exit 1; }; done
    compare "${logs[0]}" "${logs[1]}"; exit $?
fi
[[ ${#logs[@]} -eq 0 ]] || { echo "unexpected argument '${logs[0]}' (try --help)"; exit 1; }

# ---------------------------------------------------------------- checks, then into the background
for w in "$A" "$B"; do
    [[ -n "$w" && -f "$w/env/ocean_setup.sh" && -f "$w/benchmarks/poisson_solver.jl" ]] ||
        { echo "not a worktree of this repository: '${w}' (make the candidate first: setup/make_candidate.sh)"; exit 1; }
done
A="$(cd "$A" && pwd)"; B="$(cd "$B" && pwd)"
[[ "$A" != "$B" ]] || { echo "A and B are the same folder: $A"; exit 1; }
[[ "$comm" == MPI || "$comm" == NCCL ]] || { echo "--comm must be MPI or NCCL"; exit 1; }
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "--gpus needs a number"; exit 1; }
if [[ -n "$bscript" ]]; then
    [[ -f "$bscript" ]] || { echo "no such file: $bscript"; exit 1; }
    bscript="$(cd "$(dirname "$bscript")" && pwd)/$(basename "$bscript")"
fi
proj_a=(); proj_b=()
if [[ "$comm" == NCCL ]]; then
    for w in "$A" "$B"; do
        [[ -f "$w/envs/nccl/Project.toml" ]] || { echo "no envs/nccl in $w: bash $w/setup/setup_nccl_env.sh there first"; exit 1; }
    done
    proj_a=(--project "$A/envs/nccl"); proj_b=(--project "$B/envs/nccl")
fi
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found: run this on a GPU server (pelee, rondeau)"; exit 1; }
[[ $profile -eq 0 ]] || command -v python3 >/dev/null || { echo "--profile needs python3 for its tables"; exit 1; }

stamp="$(date +%Y%m%d-%H%M)"
if [[ -z "${COMPARE_SPEED_CHILD:-}" && $wait_end -eq 0 ]]; then
    mkdir -p "$B/logs"
    log="$B/logs/compare_speed_$stamp.out"
    COMPARE_SPEED_CHILD=1 setsid nohup bash "$0" "${args0[@]}" > "$log" 2>&1 < /dev/null &
    echo "Speed comparison started in the background (pid $!); about $(( profile ? 35 : 25 )) minutes at 1024³. Survives logout."
    echo "  A: $A"
    echo "  B: $B${bscript:+ (running $bscript)}"
    echo "  follow:  tail -f $log"
    echo "  stop:    kill $!   (then kill the run it started: see 'started: pid' in the log)"
    exit 0
fi

# ---------------------------------------------------------------- the two runs
free_gpus() {
    local busy; busy="$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader | sort -u)"
    nvidia-smi --query-gpu=uuid --format=csv,noheader | grep -vcFf <(echo "${busy:-none}")
}
run_one() {   # run_one <tag> <worktree> <script> <project args...>: prints the log path last
    local tag="$1" w="$2" script="$3"; shift 3
    local waited=0 out
    until [[ "$(free_gpus)" -ge "$n" ]]; do
        [[ $waited -ge 60 ]] && { echo "Fewer than $n free GPUs for 60 minutes; stopping." >&2; return 1; }
        [[ $waited -eq 0 ]] && echo "Waiting for $n free GPUs (checking every 2 minutes, up to 60) ..." >&2
        sleep 120; waited=$((waited + 2))
    done
    local pre=() extra=()
    if [[ $profile -eq 1 ]]; then
        pre=(--prefix "nsys profile --trace=cuda,mpi,nvtx --mpi-impl=openmpi --capture-range=cudaProfilerApi --capture-range-end=stop --force-overwrite=true -o $pdir/${tag}_rank%q{OMPI_COMM_WORLD_RANK}")
        extra=(--profile=true)
    fi
    out="$( set +u; source "$w/env/ocean_setup.sh" >/dev/null && cd "$w" &&
            { [[ $profile -eq 0 ]] || command -v nsys >/dev/null || module load cuda/12.3.2 2>/dev/null; true; } &&
            { [[ $profile -eq 0 ]] || command -v nsys >/dev/null || { echo "no nsys here (module load cuda/12.3.2?)"; exit 1; }; } &&
            bash "$RUN_LOCAL" --wait --gpus "$n" "${pre[@]}" "$@" --job-name "speed_${tag}_${comm}_${n}gpu" "$script" \
                 --size="$size" --float="$float" --comm="$comm" "${extra[@]}" 2>&1 &&
            if [[ $profile -eq 1 ]]; then
                nsys stats --report cuda_gpu_kern_sum,cuda_gpu_mem_time_sum,cuda_api_sum --format csv \
                     --force-export=true --output "$pdir/$tag" "$pdir/${tag}_rank0.nsys-rep" >/dev/null 2>&1 ||
                nsys stats --report gpukernsum,gpumemtimesum,cudaapisum --format csv \
                     --force-export=true --output "$pdir/$tag" "$pdir/${tag}_rank0.nsys-rep" ||
                echo "nsys stats failed on $pdir/${tag}_rank0.nsys-rep (the run itself is fine)"
            fi )"
    local rc=$?
    echo "$out" >&2
    local l; l="$(sed -n 's/^log: *//p' <<<"$out" | tail -1)"
    [[ -n "$l" && "$l" != /* ]] && l="$w/$l"    # run_local prints a full path since #38
    [[ -n "$l" ]] && echo "$l"
    return $rc
}

pdir="$B/logs/speed_profile_$stamp"
[[ $profile -eq 1 ]] && mkdir -p "$pdir"
echo "== $(date '+%F %T') A: $A"
la="$(run_one A "$A" benchmarks/poisson_solver.jl "${proj_a[@]}")" || { echo "Run A failed${la:+: see $la}"; exit 1; }
echo "== $(date '+%F %T') B: $B${bscript:+ (running $bscript)}"
lb="$(run_one B "$B" "${bscript:-benchmarks/poisson_solver.jl}" "${proj_b[@]}")" || { echo "Run B failed${lb:+: see $lb}"; exit 1; }

mkdir -p "$B/results/tests"
summary="$B/results/tests/speed_${OCEAN_MACHINE:-$(hostname -s)}_$stamp.md"
echo
compare "$la" "$lb" "$A" "$B" | tee "$summary"
rc=$?
[[ -n "$bscript" ]] && echo "B ran $bscript instead of the benchmark." >> "$summary"
if [[ $profile -eq 1 ]]; then
    echo
    { echo; profile_table "$pdir/A" "$pdir/B" "$(field "$la" t_solve_min_ms)" "$(field "$lb" t_solve_min_ms)"
      echo; echo "Reports (open in the Nsight Systems GUI): \`$pdir/{A,B}_rank*.nsys-rep\`"; } | tee -a "$summary"
fi
echo
echo "Saved: $summary"
exit $rc

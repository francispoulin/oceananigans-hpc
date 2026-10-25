#!/bin/bash
# Checks tools/compare_speed.sh without GPUs or Julia: two fake worktrees whose tools/run_local.sh
# writes a "RESULT poisson" line, and a fake nvidia-smi. Runs on every pull request (via
# tests/ci/run_all.sh) and anywhere with bash:
#
#     bash tests/ci/test_compare_speed.sh
#
# Checked: --report on two logs (a 20% slowdown is flagged with exit status 1; the same speed passes;
# a different p_std is flagged); a full --wait run uses each worktree's own environment and script,
# passes the options on, saves the summary in B and names both versions; --b-script replaces B's
# script; bad arguments are refused before anything runs.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="$ROOT/tools/compare_speed.sh"
fails=0
report() {   # ok what [details]
    if [[ "$1" -eq 1 ]]; then echo "PASS  $2"; else echo "FAIL  $2"; [[ -n "${3:-}" ]] && sed 's/^/      /' <<<"$3"; fails=$((fails+1)); fi
}
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
line() {   # line <t_solve_min> <p_std>
    echo "RESULT poisson solver=FourierTridiagonal size=1024x1024x1024 gpus=4 comm=MPI float=Float32 t_solve_min_ms=$1 t_solve_median_ms=$1 t_transposes_ms=71.9 p_std=$2 p_mean=0 p_rms=$2 mem_GiB=19.20 finite=true shared_gpu=false gpu=\"NVIDIA A100-SXM4-40GB\""
}

# 1. --report
line 159.4 9.427758250959e-02 > "$t/a.out"; line 191.9 9.427758251002e-02 > "$t/b.out"
line 160.1 9.427758250959e-02 > "$t/c.out"; line 159.4 9.5e-02 > "$t/d.out"
out="$(bash "$CS" --report "$t/a.out" "$t/b.out")" && ok=0 || ok=1
[[ "$out" == *"CHECK: B is 20.4% slower"* && "$out" == *"| 87.5 | 120.0 |"* && "$out" == *"A100-SXM4-40GB"* ]] || ok=0
report $ok "--report: 20% slower is flagged (exit status 1), with the rest of the time shown" "$out"
out="$(bash "$CS" --report "$t/a.out" "$t/c.out")" && ok=1 || ok=0
[[ "$out" == *"OK: B is 0.4% slower"* ]] || ok=0
report $ok "--report: within the tolerance passes" "$out"
out="$(bash "$CS" --report "$t/a.out" "$t/d.out")" && ok=0 || ok=1
[[ "$out" == *"DIFFERS"* ]] || ok=0
report $ok "--report: a different p_std is flagged" "$out"
out="$(bash "$CS" --report "$t/a.out" 2>&1)" && ok=0 || ok=1
report $ok "--report: needs two logs" "$out"

# 2. a full run with fake worktrees and a fake nvidia-smi
mkdir -p "$t/bin"
cat > "$t/bin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in *query-compute-apps*) ;; *) printf 'GPU-0\nGPU-1\nGPU-2\nGPU-3\n' ;; esac
EOF
chmod +x "$t/bin/nvidia-smi"
for w in A B; do
    mkdir -p "$t/$w/env" "$t/$w/benchmarks" "$t/$w/tools"
    echo "export FAKE_TREE=$w" > "$t/$w/env/ocean_setup.sh"
    touch "$t/$w/benchmarks/poisson_solver.jl"
    printf '[[deps.Oceananigans]]\nversion = "0.11%s.0"\n' "$([[ $w == A ]] && echo 3 || echo 6)" > "$t/$w/Manifest.toml"
    sed -i "1i julia_version = \"1.1$([[ $w == A ]] && echo 0 || echo 3).0\"" "$t/$w/Manifest.toml"
    # fake run_local.sh: records its arguments, writes a log with a RESULT line (B 10% slower)
    cat > "$t/$w/tools/run_local.sh" <<EOF
#!/bin/bash
mkdir -p logs; echo "tree=\$FAKE_TREE args=\$*" > logs/args.txt
echo "log:      logs/run.out"
{ echo "# \$*"; echo "$(line "$([[ $w == A ]] && echo 100.0 || echo 110.0)" 9.4e-02)"; } > logs/run.out
EOF
done
echo "" > "$t/variant.jl"
out="$(PATH="$t/bin:$PATH" bash "$CS" --a "$t/A" --b "$t/B" --wait --gpus=4 --tolerance 15 2>&1)"; rc=$?
ok=1
[[ $rc -eq 0 && "$out" == *"OK: B is 10.0% slower"* ]] || ok=0
grep -q "tree=A .*--gpus 4 .*benchmarks/poisson_solver.jl --size=1024x1024x1024 --float=Float32 --comm=MPI" "$t/A/logs/args.txt" || ok=0
grep -q "tree=B " "$t/B/logs/args.txt" || ok=0
s="$(ls "$t"/B/results/tests/speed_*.md 2>/dev/null | head -1)"
[[ -n "$s" ]] && grep -q "Oceananigans 0.113.0, Julia 1.10.0" "$s" && grep -q "Oceananigans 0.116.0, Julia 1.13.0" "$s" || ok=0
report $ok "--wait: each worktree's own environment, options passed on, summary in B with both versions" "$out"
out="$(PATH="$t/bin:$PATH" bash "$CS" --a "$t/A" --b "$t/B" --wait --b-script "$t/variant.jl" 2>&1)"; rc=$?
grep -q "tree=B .*$t/variant.jl --size" "$t/B/logs/args.txt" && [[ $rc -eq 1 && "$out" == *"CHECK: B is 10.0% slower"* ]] && ok=1 || ok=0
report $ok "--b-script: B runs the given file; 10% over the default 5% tolerance is flagged" "$out"

# 3. refused before anything runs
rm -f "$t/A/logs/args.txt"
out="$(PATH="$t/bin:$PATH" bash "$CS" --a "$t/A" --b "$t/nothere" --wait 2>&1)" && ok=0 || ok=1
[[ "$out" == *"not a worktree"* && ! -e "$t/A/logs/args.txt" ]] || ok=0
report $ok "a missing worktree is refused, nothing runs" "$out"
out="$(PATH="$t/bin:$PATH" bash "$CS" --a "$t/A" --b "$t/B" --comm NCCL --wait 2>&1)" && ok=0 || ok=1
[[ "$out" == *"no envs/nccl"* && ! -e "$t/A/logs/args.txt" ]] || ok=0
report $ok "--comm NCCL without envs/nccl is refused, nothing runs" "$out"

echo "$fails failure(s)"
exit $(( fails > 0 ))

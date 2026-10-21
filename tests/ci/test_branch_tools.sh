#!/bin/bash
# Checks tools/test_branch.sh and tools/publish_summary.sh against a throwaway local repository
# (a bare "GitHub" and a clone, as on a machine), without GPUs, Julia or network. Runs on every
# pull request (via tests/ci/run_all.sh) and anywhere with bash and git:
#
#     bash tests/ci/test_branch_tools.sh
#
# Checked: the worktree is created at the branch and the clone stays on main, untouched; a lock
# held by a live process stops a second test, a stale one does not; too few free GPUs stop the
# tests (both "busy" cases exit with 75, "try later"); --latest publishes only the summary file, on
# top of main, as results/<name>, without changing the clone; publishing twice does nothing; a file
# that is not a summary is refused; an earlier summary left in the worktree does not block switching
# to a commit that contains it; --clean removes the worktree.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
report() {   # ok what [details]
    if [[ "$1" -eq 1 ]]; then echo "PASS  $2"; else echo "FAIL  $2"; [[ -n "${3:-}" ]] && sed 's/^/      /' <<<"$3"; fails=$((fails+1)); fi
}
g() { git -c push.negotiate=false -c user.name=ci -c user.email=ci@example.org -c init.defaultBranch=main "$@"; }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
g init -q --bare "$t/remote.git"
g clone -q "$t/remote.git" "$t/seed" 2>/dev/null
mkdir -p "$t/seed/tools" "$t/seed/results/tests"
cp "$ROOT/tools/test_branch.sh" "$ROOT/tools/publish_summary.sh" "$t/seed/tools/"
echo "seed" > "$t/seed/README.md"; touch "$t/seed/results/tests/.keep"
( cd "$t/seed" && g add -A && g commit -qm "main" && g push -q origin HEAD:main &&
  g switch -qc claude/feature && echo "feature" > feature.txt && g add feature.txt &&
  g commit -qm "feature" && g push -q origin claude/feature ) || { echo "setup failed"; exit 1; }
feature="$(git -C "$t/seed" rev-parse HEAD)"

g clone -q "$t/remote.git" "$t/clone" 2>/dev/null          # the clone on a machine
git -C "$t/clone" config user.name ci; git -C "$t/clone" config user.email ci@example.org
main0="$(git -C "$t/clone" rev-parse HEAD)"
WT="$t/clone-test"

# 1. dry run: worktree at the branch, clone untouched
out="$(bash "$t/clone/tools/test_branch.sh" claude/feature --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" == "$feature" && -f "$WT/feature.txt" &&
   "$(git -C "$t/clone" rev-parse HEAD)" == "$main0" && "$(git -C "$t/clone" branch --show-current)" == main &&
   -z "$(git -C "$t/clone" status --porcelain)" && "$out" == *"(dry run"* ]] && ok=1 || ok=0
report $ok "test_branch.sh: worktree at the branch, clone still on main and clean" "$out"

# 2. a live lock (this shell, this machine) stops a second test; 3. a stale one does not
echo "pid $$ $(hostname -s)" > "$WT/.test_branch.lock"
out="$(bash "$t/clone/tools/test_branch.sh" claude/feature --dry-run 2>&1)"; rc=$?
[[ $rc -eq 75 && "$out" == *"Another test"* ]] && ok=1 || ok=0
report $ok "test_branch.sh: refuses while another test holds the lock" "$out"
( exit 0 ) & dead=$!; wait $dead
echo "pid $dead $(hostname -s)" > "$WT/.test_branch.lock"
out="$(bash "$t/clone/tools/test_branch.sh" claude/feature --dry-run 2>&1)" && ok=1 || ok=0
report $ok "test_branch.sh: ignores a stale lock (process gone)" "$out"
rm -f "$WT/.test_branch.lock"

# 3b. not enough free GPUs (a stand-in nvidia-smi: 2 GPUs, both busy): nothing runs, no lock left
mkdir -p "$t/bin"
cat > "$t/bin/nvidia-smi" <<'SMI'
#!/bin/bash
case "$*" in *query-compute-apps*) printf 'GPU-a\nGPU-b\n' ;; *) printf '0, GPU-a\n1, GPU-b\n' ;; esac
SMI
chmod +x "$t/bin/nvidia-smi"
out="$(PATH="$t/bin:$PATH" CC_CLUSTER='' bash "$t/clone/tools/test_branch.sh" claude/feature 2>&1)"; rc=$?
[[ $rc -eq 75 && "$out" == *"Only 0 free GPU(s)"*"Nothing run"* && ! -f "$WT/.test_branch.lock" ]] && ok=1 || ok=0
report $ok "test_branch.sh: stops before the tests when too few GPUs are free" "$out"

# 3c. --if-clean refuses a summary with skipped steps (and publishes nothing)
mkdir -p "$WT/results/tests"
printf '# Platform tests on ci, 2026-10-20 11:00:00\n\noceananigans-hpc v0 (abc test). GPUs: 1 4.\n**2 passed, 0 failed, 2 skipped or warnings.**\n' \
    > "$t/skipped.md"
out="$(bash "$t/clone/tools/publish_summary.sh" --if-clean "$t/skipped.md" 2>&1)" && ok=0 || ok=1
[[ "$out" == *"Not published"* && -z "$(git -C "$t/remote.git" for-each-ref refs/heads/results)" ]] || ok=0
report $ok "publish_summary.sh --if-clean: refuses a summary with skipped steps" "$out"

# 4. publish --latest: only the summary, on top of main, clone unchanged
mkdir -p "$WT/results/tests"
printf '# Platform tests on ci, 2026-10-20 12:00:00\n\noceananigans-hpc v0 (abc test). GPUs: 1 4.\n**21 passed, 0 failed, 0 skipped or warnings.**\n' \
    > "$WT/results/tests/ci_20261020-1200.md"
out="$(bash "$t/clone/tools/publish_summary.sh" --if-clean --latest 2>&1)"; rc=$?
b=results/ci_20261020-1200
pub="$(git -C "$t/remote.git" rev-parse -q --verify "$b" 2>/dev/null)"
[[ $rc -eq 0 && -n "$pub" && "$(git -C "$t/remote.git" rev-parse "$b^")" == "$main0" &&
   "$(git -C "$t/remote.git" diff --name-status "$main0" "$b")" == "A	results/tests/ci_20261020-1200.md" &&
   "$(git -C "$t/clone" rev-parse HEAD)" == "$main0" && -z "$(git -C "$t/clone" status --porcelain)" ]] && ok=1 || ok=0
report $ok "publish_summary.sh --latest: one file on top of main, as $b; clone unchanged" "$out"

# 5. publishing twice does nothing; 6. not a summary is refused
out="$(bash "$t/clone/tools/publish_summary.sh" "$WT/results/tests/ci_20261020-1200.md" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"Already published"* ]] && ok=1 || ok=0
report $ok "publish_summary.sh: a second publish does nothing" "$out"
echo "not a summary" > "$t/other.md"
out="$(bash "$t/clone/tools/publish_summary.sh" "$t/other.md" 2>&1)" && ok=0 || ok=1
report $ok "publish_summary.sh: refuses a file that is not a summary" "$out"

# 6b. the worktree still holds that summary, untracked, and the next commit contains it (as after a
# merge): switching is not blocked, and the earlier copy is kept in local/old_summaries/
out="$(bash "$t/clone/tools/test_branch.sh" "$b" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(git -C "$WT" rev-parse HEAD)" == "$pub" &&
   -f "$WT/local/old_summaries/ci_20261020-1200.md" && -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] && ok=1 || ok=0
report $ok "test_branch.sh: an earlier summary left in the worktree does not block the next commit" "$out"

# 7. --clean removes the worktree
out="$(bash "$t/clone/tools/test_branch.sh" --clean 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -e "$WT" && "$(git -C "$t/clone" worktree list | wc -l)" -eq 1 ]] && ok=1 || ok=0
report $ok "test_branch.sh --clean: worktree removed" "$out"

echo "$fails failure(s)"
exit $(( fails > 0 ))

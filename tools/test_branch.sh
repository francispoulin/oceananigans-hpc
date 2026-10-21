#!/bin/bash
# Run the platform tests of a branch (or a tag or commit) on this machine WITHOUT switching the
# clone: the branch is checked out in a second folder, a git worktree next to the clone
# (<clone>-test), and the tests run there. The clone stays on main, so queued jobs and other runs
# are never affected. From anywhere (it sets up the environment itself):
#
#     bash /path/to/oceananigans-hpc/tools/test_branch.sh claude/some-change          # 1 and 4 GPUs
#     bash /path/to/oceananigans-hpc/tools/test_branch.sh claude/some-change --gpus "1 2"
#     bash /path/to/oceananigans-hpc/tools/test_branch.sh main                        # main as on GitHub
#     bash /path/to/oceananigans-hpc/tools/test_branch.sh --clean                     # remove the worktree
#
# Options:
#   --gpus "1 4"   GPU counts for tools/run_tests.sh (default: its own, 1 and 4)
#   --no-publish   keep the summary here (default: publish it, see tools/publish_summary.sh)
#   --dry-run      fetch and prepare the worktree, show what would run, run nothing
#   --clean        remove the worktree (refused while a test from it is running or queued)
#
# What it does: git fetch; the worktree is created (or moved) to origin/<branch>, detached, so the
# same branch can also be checked out elsewhere; the clone's machine-specific LocalPreferences.toml
# files (MPI setup, not under version control) are copied into it; then tools/run_tests.sh runs
# there with the worktree's own environment (OCEAN_HPC_ROOT = the worktree).
#   pelee/rondeau: the tests run now (about 10 min) if enough GPUs are free (otherwise nothing runs);
#   at the end the summary is published if nothing failed or was skipped.
#   Alliance: run_tests.sh submits one job and this script stops; when the job has ended, publish
#   the summary with:  bash /path/to/oceananigans-hpc/tools/publish_summary.sh --if-clean --latest
# One test at a time per machine: a lock in the worktree (the running process, or the queued job)
# stops a second test from switching the worktree under the first. pelee and rondeau share one
# clone, and so one worktree.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The main clone, also when this script is run from the worktree itself
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    common="$(cd "$here" && cd "$(git rev-parse --git-common-dir)" && pwd)"
CLONE="$(dirname "$common")"
WT="${TEST_WORKTREE:-$CLONE-test}"
LOCK="$WT/.test_branch.lock"

ref=""; gpus=(); publish=1; dry=0; clean=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpus) [[ -n "${2:-}" ]] || { echo "--gpus needs a value, e.g. --gpus \"1 2\""; exit 1; }
                gpus=(--gpus "$2"); shift 2 ;;
        --gpus=*) gpus=(--gpus "${1#*=}"); shift ;;
        --no-publish) publish=0; shift ;;
        --dry-run) dry=1; shift ;;
        --clean) clean=1; shift ;;
        -*) echo "unknown option $1 (try --help)"; exit 1 ;;
        *) [[ -z "$ref" ]] || { echo "one branch only (got '$ref' and '$1')"; exit 1; }; ref="$1"; shift ;;
    esac
done

# lock_holder: prints who holds the lock if it is still active, nothing if free or stale
lock_holder() {
    [[ -f "$LOCK" ]] || return 0
    local kind id host
    read -r kind id host < "$LOCK"
    case "$kind" in
        job) command -v squeue >/dev/null && [[ -n "$(squeue -h -j "$id" 2>/dev/null)" ]] &&
                 echo "Slurm job $id (see squeue -u \$USER)" ;;
        pid) if [[ "$host" != "$(hostname -s)" ]]; then
                 echo "process $id on $host (if nothing runs there any more, remove $LOCK)"
             elif kill -0 "$id" 2>/dev/null; then echo "process $id on this machine"; fi ;;
    esac
}

busy="$(lock_holder)"
if [[ $clean -eq 1 ]]; then
    [[ -z "$busy" ]] || { echo "Not removed: a test from $WT is still active: $busy"; exit 1; }
    [[ -d "$WT" ]] || { echo "No worktree at $WT"; git -C "$CLONE" worktree prune; exit 0; }
    git -C "$CLONE" worktree remove --force "$WT" && git -C "$CLONE" worktree prune && echo "Removed $WT"
    exit $?
fi
[[ -n "$ref" ]] || { echo "usage: test_branch.sh <branch> [--gpus \"1 2\"] [--no-publish] [--dry-run]   (or --clean)"; exit 1; }
[[ -z "$busy" ]] || { echo "Another test is using $WT: $busy. Wait for it to end."; exit 1; }

echo "== Fetching ($CLONE)"
git -C "$CLONE" fetch --quiet origin || { echo "git fetch failed"; exit 1; }
if git -C "$CLONE" rev-parse -q --verify "origin/$ref^{commit}" >/dev/null; then target="origin/$ref"
elif git -C "$CLONE" rev-parse -q --verify "$ref^{commit}" >/dev/null; then target="$ref"
else echo "no branch, tag or commit '$ref' (after git fetch)"; exit 1; fi

echo "== Worktree $WT -> $target"
git -C "$CLONE" worktree prune
if [[ -d "$WT/.git" || -f "$WT/.git" ]]; then
    [[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] ||
        { echo "$WT has local changes to tracked files; not touching it (git -C $WT status)"; exit 1; }
    git -C "$WT" checkout --quiet --detach "$target" || exit 1
else
    [[ ! -e "$WT" ]] || { echo "$WT exists but is not a worktree of $CLONE; move it away first"; exit 1; }
    git -C "$CLONE" worktree add --quiet --detach "$WT" "$target" || exit 1
fi
if [[ -f "$CLONE/LocalPreferences.toml" ]]; then cp "$CLONE/LocalPreferences.toml" "$WT/"
else echo "   (no LocalPreferences.toml in the clone: run setup/setup.sh there first)"; fi
[[ -f "$CLONE/viz/LocalPreferences.toml" ]] && cp "$CLONE/viz/LocalPreferences.toml" "$WT/viz/"   # usually none
echo "   $(git -C "$WT" describe --tags --always) ($(git -C "$WT" log -1 --format='%h %s'))"

cmd=(bash "$WT/tools/run_tests.sh" "${gpus[@]}")

if [[ $dry -eq 1 ]]; then
    echo "== Would run, with the worktree's environment (source $WT/env/ocean_setup.sh):"
    echo "   ${cmd[*]}"
    [[ $publish -eq 1 ]] && echo "   then: bash $here/publish_summary.sh --if-clean <summary>"
    echo "(dry run: no tests run)"
    exit 0
fi

# pelee/rondeau: enough free GPUs now? Otherwise stop here rather than skip every GPU test.
if [[ -z "${CC_CLUSTER:-}" ]] && command -v nvidia-smi >/dev/null; then
    want=$(tr ' ' '\n' <<<"${gpus[1]:-1 4}" | sort -n | tail -1)
    busy_uuids="$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader | sort -u)"
    nfree=0
    while IFS=', ' read -r _ uuid; do grep -q "$uuid" <<<"$busy_uuids" || nfree=$((nfree + 1)); done \
        < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)
    if (( nfree < want )); then
        echo "Only $nfree free GPU(s) on $(hostname -s); the tests need $want. Nothing run."
        echo "Try later, on the other server, or with fewer GPUs (--gpus \"1 2\")."
        exit 1
    fi
fi

echo "== Platform tests"
echo "pid $$ $(hostname -s)" > "$LOCK"
out="$(mktemp)"
# A subshell, so the worktree's environment does not stay in the caller's shell
( source "$WT/env/ocean_setup.sh" && "${cmd[@]}" ) 2>&1 | tee "$out"
status=${PIPESTATUS[0]}

job="$(sed -n 's/^Submitted batch job \([0-9]*\).*/\1/p' "$out" | tail -1)"
summary="$(sed -n 's/.*Summary: \(.*\.md\)$/\1/p' "$out" | tail -1)"
rm -f "$out"
if [[ -n "$job" ]]; then                               # Alliance: the tests run in that job
    echo "job $job $(hostname -s)" > "$LOCK"
    echo
    echo "Job $job runs the tests of $target from $WT (the clone is untouched)."
    echo "When it has ended (squeue -u \$USER is empty of it), publish the summary with:"
    echo "    bash $here/publish_summary.sh --if-clean --latest"
    exit 0
fi
rm -f "$LOCK"
[[ -n "$summary" && -f "$summary" ]] || { echo "No summary found (see the output above)"; exit 1; }
if [[ $publish -eq 1 ]]; then
    bash "$here/publish_summary.sh" --if-clean "$summary" || echo "Not published; the summary is in $summary"
fi
exit "$status"

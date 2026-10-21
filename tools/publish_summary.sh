#!/bin/bash
# Publish a platform-test summary to GitHub without changing anything in this clone: the summary
# file alone is committed on top of origin/main, as a new branch results/<machine>_<date-time>, and
# pushed. It is then merged into the pull request that needs it (by Claude or by hand), and the
# branch deleted. This is the one thing a machine pushes (CONTRIBUTING.md, "Clones on the machines").
#
#     bash tools/publish_summary.sh results/tests/pelee_20261020-1904.md
#     bash tools/publish_summary.sh --latest     # the newest summary written by a test on this machine
#     bash tools/publish_summary.sh --if-clean --latest   # only if nothing failed or was skipped
#
# --latest looks in the test worktree (<clone>-test/results/tests, from tools/test_branch.sh) and in
# $OCEAN_JOB_DIR/results/tests (Trillium: $SCRATCH/oceananigans-hpc) for the newest summary that is
# not already part of the repository, shows its first lines, and publishes it. Run it on a login node or pelee/rondeau (it needs GitHub; compute nodes
# usually can't reach it). Needs git's user.name and user.email (git config --global ...).

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    common="$(cd "$here" && cd "$(git rev-parse --git-common-dir)" && pwd)"
CLONE="$(dirname "$common")"
WT="${TEST_WORKTREE:-$CLONE-test}"

if_clean=0
[[ "${1:-}" == --if-clean ]] && { if_clean=1; shift; }
[[ $# -eq 1 ]] || { echo "usage: publish_summary.sh [--if-clean] <summary.md> | --latest"; exit 1; }
if [[ "$1" == --latest ]]; then
    dirs=("$WT/results/tests")
    [[ -n "${OCEAN_JOB_DIR:-}" ]] && dirs+=("$OCEAN_JOB_DIR/results/tests")
    [[ "${CC_CLUSTER:-}" == trillium && -n "${SCRATCH:-}" ]] && dirs+=("$SCRATCH/oceananigans-hpc/results/tests")
    found=()
    shopt -s nullglob
    for d in "${dirs[@]}"; do
        for f in "$d"/*.md; do
            # Skip summaries that are part of the repository (checked out in the worktree): checking
            # out a commit gives them a new time, so they would look newer than the test just run.
            git -C "$d" ls-files --error-unmatch "$f" >/dev/null 2>&1 || found+=("$f")
        done
    done
    shopt -u nullglob
    file=""
    [[ ${#found[@]} -gt 0 ]] && file="$(ls -t "${found[@]}" | head -1)"
    [[ -n "$file" ]] || { echo "No summary found in: ${dirs[*]}"; exit 1; }
else
    file="$1"
fi
[[ -f "$file" ]] || { echo "No such file: $file"; exit 1; }
head -1 "$file" | grep -q '^# Platform tests on ' || { echo "$file is not a test summary (no '# Platform tests on' line)"; exit 1; }
name="$(basename "$file")"
echo "Summary: $file"
sed -n '1p;3,4p' "$file" | sed 's/^/    /'
if [[ $if_clean -eq 1 ]] && ! grep -qE '^\*\*[0-9]+ passed, 0 failed, 0 skipped or warnings\.\*\*$' "$file"; then
    echo "Not published: some steps failed, were skipped or warned (--if-clean)."
    echo "To publish it anyway (e.g. a deliberate partial run): bash $here/publish_summary.sh $file"
    exit 1
fi

for key in user.name user.email; do
    [[ -n "$(git -C "$CLONE" config "$key")" ]] || { echo "git $key is not set: git config --global $key \"...\""; exit 1; }
done

git -C "$CLONE" fetch --quiet origin main
if [[ "$(git -C "$CLONE" rev-parse -q --verify "origin/main:results/tests/$name" 2>/dev/null)" == "$(git -C "$CLONE" hash-object "$file")" ]]; then
    echo "Already in main, identical: nothing to publish."; exit 0
fi
branch="results/${name%.md}"
if [[ -n "$(git -C "$CLONE" ls-remote --heads origin "$branch")" ]]; then
    echo "Already published as $branch (git ls-remote shows it): nothing to do."; exit 0
fi

# Commit with git's plumbing and a temporary index: the clone's files, index and branches stay as they are.
idx="$(mktemp)"; trap 'rm -f "$idx"' EXIT
blob="$(git -C "$CLONE" hash-object -w "$file")"
GIT_INDEX_FILE="$idx" git -C "$CLONE" read-tree origin/main
GIT_INDEX_FILE="$idx" git -C "$CLONE" update-index --add --cacheinfo "100644,$blob,results/tests/$name"
tree="$(GIT_INDEX_FILE="$idx" git -C "$CLONE" write-tree)"
msg="Test summary: ${name%.md}

$(sed -n '3,4p' "$file")

Published from $(hostname -s) by tools/publish_summary.sh."
commit="$(git -C "$CLONE" commit-tree "$tree" -p origin/main -m "$msg")"
git -C "$CLONE" push --quiet origin "$commit:refs/heads/$branch"

url="$(git -C "$CLONE" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
echo "Published: branch $branch"
echo "    $url/tree/$branch"

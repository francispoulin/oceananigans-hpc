#!/bin/bash
# The platform tests of one commit, run by a Buildkite agent on pelee or rondeau (docs/ci.md).
# .buildkite/pipeline.yml calls it in the agent's checkout of the commit being built:
#
#     bash tools/ci_platform_tests.sh                 # in a Buildkite job: tests $BUILDKITE_COMMIT
#     bash tools/ci_platform_tests.sh <commit>        # by hand, to try it outside Buildkite
#
# It uses the machine's own clone (OCEAN_HPC_CLONE, set in the agent's environment; default
# /mnt/autofs/bow.math/scratch/$USER/software/oceananigans-hpc) and runs that clone's
# tools/test_branch.sh on the commit: worktree next to the clone, the clone's LocalPreferences.toml,
# one test at a time, free GPUs only. The agent's own checkout only supplies this script.
#   - GPUs or the worktree busy (test_branch.sh exits 75): wait and try again, every 5 minutes, for
#     up to OCEAN_CI_WAIT_MINUTES (default 120); then the build fails with "busy".
#   - The summary is shown on the build page (an annotation) and kept as a build artifact.
#   - The build passes only if the summary is clean: nothing failed, skipped or warned.
#   - OCEAN_CI_PUBLISH=1 (set it on a build, e.g. for a release) also publishes a clean summary as a
#     results/<machine>_<date> branch (tools/publish_summary.sh); this needs a key that can push.
#   - OCEAN_CI_GPUS="1 2" passes --gpus to the tests (default: run_tests.sh's own, 1 and 4).
# Fetching uses HTTPS (the repository is public), so the agent needs no SSH key to test. A commit
# that is not on a branch of this repository (e.g. from a fork) is not found, and nothing runs.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail

commit="${1:-${BUILDKITE_COMMIT:-}}"
[[ -n "$commit" ]] || { echo "ci_platform_tests.sh: no commit (give one, or run inside a Buildkite job)"; exit 1; }
CLONE="${OCEAN_HPC_CLONE:-/mnt/autofs/bow.math/scratch/$USER/software/oceananigans-hpc}"
[[ -f "$CLONE/tools/test_branch.sh" ]] ||
    { echo "ci_platform_tests.sh: no tools/test_branch.sh in $CLONE (set OCEAN_HPC_CLONE to the machine's clone)"; exit 1; }
wait_min="${OCEAN_CI_WAIT_MINUTES:-120}"
gpus=(); [[ -n "${OCEAN_CI_GPUS:-}" ]] && gpus=(--gpus "$OCEAN_CI_GPUS")

# Fetch over HTTPS, push (only when publishing) over SSH as before; for git commands in this job only.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_0='git@github.com:'
export GIT_CONFIG_KEY_1='url.git@github.com:.pushInsteadOf' GIT_CONFIG_VALUE_1='git@github.com:'

out="$(mktemp)"; trap 'rm -f "$out"' EXIT
start=$SECONDS
while true; do
    echo "--- :test_tube: Platform tests of ${commit:0:12} on $(hostname -s) (clone: $CLONE)"
    bash "$CLONE/tools/test_branch.sh" "$commit" --no-publish "${gpus[@]}" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 75 ]] || break
    if (( SECONDS - start + 300 > wait_min * 60 )); then
        echo "^^^ +++"
        echo "Still busy after $wait_min minutes (GPUs or another test); nothing was run."
        command -v buildkite-agent >/dev/null && [[ -n "${BUILDKITE_JOB_ID:-}" ]] &&
            buildkite-agent annotate --style warning --context platform "Not run: GPUs or the test worktree on $(hostname -s) stayed busy for $wait_min minutes. Retry the build later."
        exit 75
    fi
    echo "Busy; trying again in 5 minutes ($(( (SECONDS - start) / 60 )) of $wait_min minutes so far)."
    sleep 300
done

summary="$(sed -n 's/.*Summary: \(.*\.md\)$/\1/p' "$out" | tail -1)"
if [[ -z "$summary" || ! -f "$summary" ]]; then
    echo "^^^ +++"
    echo "No test summary (test_branch.sh exited with $rc; see above)."
    exit "$(( rc == 0 ? 1 : rc ))"
fi
clean=0
grep -qE '^\*\*[0-9]+ passed, 0 failed, 0 skipped or warnings\.\*\*$' "$summary" && clean=1

if command -v buildkite-agent >/dev/null && [[ -n "${BUILDKITE_JOB_ID:-}" ]]; then
    style=error; [[ $clean -eq 1 ]] && style=success
    buildkite-agent annotate --style "$style" --context platform < "$summary"
    ( cd "$(dirname "$summary")" && buildkite-agent artifact upload "$(basename "$summary")" )
fi

if [[ $clean -eq 1 && "${OCEAN_CI_PUBLISH:-0}" == 1 ]]; then
    bash "$CLONE/tools/publish_summary.sh" --if-clean "$summary" || echo "Not published (see above)."
fi
if [[ $clean -ne 1 ]]; then
    echo "^^^ +++"
    echo "Not clean: some steps failed, were skipped or warned. Summary: $summary"
    exit "$(( rc == 0 ? 1 : rc ))"
fi
exit "$rc"

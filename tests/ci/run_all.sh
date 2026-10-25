#!/bin/bash
# All the checks that need no GPUs and no Slurm: the same ones GitHub runs on every pull request
# (.github/workflows/checks.yml). Run before pushing, on any machine with bash and Python 3:
#
#     bash tests/ci/run_all.sh
#
# Uses shellcheck if it is installed (pip install shellcheck-py, or the system package).

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
status=0
scripts=()                                   # (no mapfile: macOS ships bash 3.2)
while IFS= read -r f; do scripts+=("$f"); done < <(git ls-files '*.sh')

echo "== Shell syntax (bash -n), ${#scripts[@]} scripts"
for s in "${scripts[@]}"; do bash -n "$s" || { echo "FAIL  $s"; status=1; }; done

echo "== shellcheck (warnings and errors)"
if command -v shellcheck >/dev/null; then
    shellcheck -S warning "${scripts[@]}" || status=1
else
    echo "shellcheck not installed: skipped (GitHub runs it)"
fi

echo "== Submit scripts: Slurm options per cluster"
bash tests/ci/test_submit_scripts.sh || status=1

echo "== Testing a branch: worktree and summary publishing (local throwaway repository)"
bash tests/ci/test_branch_tools.sh || status=1

echo "== Speed comparison of two worktrees (fake runs)"
bash tests/ci/test_compare_speed.sh || status=1

echo "== Cluster facts: docs tables vs jobs/gpu_request.sh, no --gpus-per-task"
python3 tests/ci/check_cluster_facts.py || status=1

echo "== Every script documented: docs/scripts.md, usage header, -h"
python3 tests/ci/check_scripts_documented.py || status=1

echo "== One Julia version: Manifests, env/julia.sh, every machine file"
python3 tests/ci/check_julia_version.py || status=1

echo "== Links in the docs"
python3 tests/ci/check_links.py || status=1

(( status == 0 )) && echo "== All checks passed" || echo "== Some checks FAILED"
exit $status

#!/bin/bash
# Brings this machine's clone and its environment up to date with main, in ONE command: after a new
# release is merged, on every machine with a clone (pelee and rondeau share one: run it once). On a
# login node (it needs internet), from anywhere:
#
#     bash /path/to/oceananigans-hpc/setup/update.sh            # update
#     bash /path/to/oceananigans-hpc/setup/update.sh --check    # only say what would change
#
# In order, stopping at the first problem (nothing after it runs):
#
#   1. Refuses unless the clone is on main with no local changes or commits, and none of your jobs
#      are queued or running (Slurm; pelee/rondeau: no Julia process of yours on this server). Jobs
#      read this clone's files and set up their environment when they start, so they could start
#      with a half-updated platform.
#   2. git pull --ff-only.
#   3. Julia: installs Manifest.toml's julia_version if it is not installed (setup/install_julia.sh).
#   4. Packages and MPI (setup/setup.sh), then the plotting environment (setup/setup_viz.sh).
#   5. tools/check_env.sh on this repository: it must end with "All checks OK".
#
# Steps 3 to 5 are run by the version of this script that the pull brought, each in a new
# environment (ocean_setup sourced after the pull). Each step is safe to repeat: after a failure, fix
# the cause and run it again. With nothing new it takes a few minutes (Julia starts several times).
# The log goes to update_logs/ next to the Julia depot. Afterwards, run ocean_setup again in your
# shell: it still has the old environment (an old julia on PATH, for example).
#
# Simulation repositories (BalancedFlows.jl, ...) are not touched: each has its own update script,
# which first checks that this platform is ready for it (docs/simulation_repos.md).

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "update.sh: $*" >&2; exit 1; }

# One command in the environment, in a child shell (the caller's shell is not changed)
in_env() { bash -c 'source "$1/env/ocean_setup.sh" >/dev/null 2>&1; shift; "$@"' _ "$ROOT" "$@"; }

# ---- 1. Is it safe? ----
preflight() {
    local branch ahead
    git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "$ROOT is not a git clone"
    branch="$(git -C "$ROOT" branch --show-current)"
    [[ "$branch" == main ]] || fail "the clone is on '${branch:-a detached commit}', not main. Switch: git -C $ROOT switch main"
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] ||
        fail "the clone has local changes (git -C $ROOT status): commit them on a branch or remove them"
    if [[ "${CC_CLUSTER:-}" == trillium && "$(hostname -s)" == tri-login* ]]; then
        fail "Trillium: run this on trig-login01, where GPU jobs are queued (docs/drac.md, section 11)"
    fi
    git -C "$ROOT" fetch --quiet --tags origin main || fail "git fetch failed (no internet? not a login node?)"
    ahead="$(git -C "$ROOT" rev-list --count origin/main..HEAD)"
    [[ "$ahead" -eq 0 ]] || fail "the clone has $ahead commit(s) that are not on GitHub's main: push them on a branch first"
}

jobs_running() {   # prints your jobs, if any
    if command -v squeue >/dev/null 2>&1; then
        squeue -h -u "$USER" -o '%i %j %T' 2>/dev/null
    else           # pelee/rondeau: jobs are processes (tools/run_local.sh); an editor's language server is not one
        pgrep -u "$USER" -a -x julia 2>/dev/null | grep -v -i languageserver
    fi
}

report() {         # what the update will change
    local now new behind jv
    now="$(git -C "$ROOT" describe --tags 2>/dev/null)"
    new="$(git -C "$ROOT" describe --tags origin/main 2>/dev/null)"
    behind="$(git -C "$ROOT" rev-list --count HEAD..origin/main)"
    jv="$(git -C "$ROOT" show origin/main:Manifest.toml | sed -n 's/^julia_version = "\(.*\)"$/\1/p')"
    echo "machine:  $(hostname -s) (${CC_CLUSTER:-no Slurm})"
    echo "clone:    $ROOT, $now -> $new ($behind commit(s) to pull)"
    echo "Julia:    $jv for the new Manifest; installed: $(in_env bash -c 'cd "$OCEAN_SOFTWARE_DIR" 2>/dev/null && ls -d julia-* 2>/dev/null | tr "\n" " "')"
    for m in Manifest.toml viz/Manifest.toml; do
        git -C "$ROOT" diff --quiet HEAD origin/main -- "$m" || echo "changes:  $m (new package versions)"
    done
}

check_safe() {
    local running
    echo "== 1. Is it safe to update?"
    preflight
    report
    running="$(jobs_running)"
    if [[ -n "$running" ]]; then
        echo "Your jobs (running or queued; they use this machine's Julia packages, which the update changes):"; sed 's/^/    /' <<<"$running"
        fail "wait until they have finished, then run this again"
    fi
    [[ -n "${CC_CLUSTER:-}" ]] || echo "pelee and rondeau share this clone: check that nothing of yours runs on the other one."
    echo "No jobs: OK"
}

# ---- 2. Pull, then 3 to 5 with the new script ----
update() {
    check_safe
    echo "== 2. Pull"
    git -C "$ROOT" pull --ff-only --quiet origin main || fail "git pull failed (above)"
    git -C "$ROOT" log --oneline -1
    # Internal: keep accepting _after_pull in future versions (an older script calls it after its pull).
    exec bash "$ROOT/setup/update.sh" _after_pull
}

after_pull() {
    echo "== 3. Julia (setup/install_julia.sh)"
    bash "$ROOT/setup/install_julia.sh" || fail "installing Julia failed (above)"
    echo "== 4. Packages and MPI (setup/setup.sh), then viz/ (setup/setup_viz.sh)"
    OCEAN_UPDATING=1 bash "$ROOT/setup/setup.sh"     || fail "setup/setup.sh failed (above)"
    OCEAN_UPDATING=1 bash "$ROOT/setup/setup_viz.sh" || fail "setup/setup_viz.sh failed (above)"
    echo "== 5. Check (tools/check_env.sh)"
    in_env bash "$ROOT/tools/check_env.sh" "$ROOT" || fail "tools/check_env.sh found problems (above)"
    echo
    echo "Updated: $(hostname -s)${CC_CLUSTER:+ ($CC_CLUSTER)}, oceananigans-hpc $(git -C "$ROOT" describe --tags), Julia $(in_env julia --startup-file=no -e 'print(VERSION)')."
    echo "Next: ocean_setup again in your shell, then each simulation repository's own update script."
}

case "${1:-}" in
    _after_pull) after_pull; exit ;;
    --check)     check_safe; echo; echo "(--check: nothing was changed)"; exit 0 ;;
    "")          ;;
    *)           fail "unknown option '$1' (bash $0 -h shows the usage)" ;;
esac

[[ -n "${OCEAN_HPC_ROOT:-}" && "$OCEAN_HPC_ROOT" != "$ROOT" ]] &&
    echo "Note: ocean_setup in this shell points to $OCEAN_HPC_ROOT; updating $ROOT." >&2
depot="$(in_env bash -c 'echo "$OCEAN_DEPOT"')"
[[ -n "$depot" ]] || fail "ocean_setup did not set OCEAN_DEPOT on this machine (bash $ROOT/tools/check_env.sh says more)"
mkdir -p "$(dirname "$depot")/update_logs" || fail "cannot create $(dirname "$depot")/update_logs"
log="$(dirname "$depot")/update_logs/update_$(hostname -s)_$(date +%Y%m%d-%H%M%S).log"
echo "Log: $log"
update 2>&1 | tee -a "$log"
exit "${PIPESTATUS[0]}"

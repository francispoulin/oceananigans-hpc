#!/bin/bash
# Checks setup/update.sh against a throwaway local repository (a bare "GitHub" and a clone, as on a
# machine), with stand-ins for squeue, julia and the setup scripts: no GPUs, Julia, Slurm or network.
# Runs on every pull request (via tests/ci/run_all.sh) and anywhere with bash and git:
#
#     bash tests/ci/test_update.sh
#
# Checked: --check changes nothing; it refuses (and pulls nothing) when the clone is not on main, has
# local changes or local commits, or when jobs are queued; an update pulls, then runs the steps in
# order with the script the pull brought, and writes its log next to the depot; it stops at the first
# step that fails.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
report() {   # ok what [details]
    if [[ "$1" -eq 1 ]]; then echo "PASS  $2"; else echo "FAIL  $2"; [[ -n "${3:-}" ]] && sed 's/^/      /' <<<"$3"; fails=$((fails+1)); fi
}
g() { git -c push.negotiate=false -c user.name=ci -c user.email=ci@example.org -c init.defaultBranch=main "$@"; }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/work/depot"
# Stand-ins: squeue lists $FAKE_JOBS; julia prints its version
printf '#!/bin/bash\n[[ -n "${FAKE_JOBS:-}" ]] && echo "$FAKE_JOBS"\nexit 0\n' > "$t/bin/squeue"
printf '#!/bin/bash\necho 1.13.2\n' > "$t/bin/julia"
chmod +x "$t/bin/squeue" "$t/bin/julia"
export PATH="$t/bin:$PATH" CC_CLUSTER=fakecluster STEPS="$t/steps"
unset OCEAN_HPC_ROOT

# The repository: the real update.sh, stand-ins for the environment and the steps it runs
g init -q --bare "$t/remote.git"
g clone -q "$t/remote.git" "$t/seed" 2>/dev/null
mkdir -p "$t/seed/env" "$t/seed/setup" "$t/seed/tools" "$t/seed/viz"
cp "$ROOT/setup/update.sh" "$t/seed/setup/"
printf 'export OCEAN_DEPOT=%q OCEAN_SOFTWARE_DIR=%q\n' "$t/work/depot" "$t/work/software" > "$t/seed/env/ocean_setup.sh"
for s in setup/install_julia setup/setup setup/setup_viz tools/check_env; do
    n="$(basename "$s")"
    printf '#!/bin/bash\necho "STEP %s"; echo %s >> "$STEPS"\nexit "${FAIL_%s:-0}"\n' "$n" "$n" "$n" > "$t/seed/$s.sh"
done
printf 'julia_version = "1.13.2"\n' > "$t/seed/Manifest.toml"; cp "$t/seed/Manifest.toml" "$t/seed/viz/"
( cd "$t/seed" && g add -A && g commit -qm "v1" && g tag v1.0.0 && g push -q --tags origin HEAD:main ) || { echo "setup failed"; exit 1; }
g clone -q "$t/remote.git" "$t/clone" 2>/dev/null                 # the clone on a machine
v1="$(git -C "$t/clone" rev-parse HEAD)"

new_release() {   # a new commit on "GitHub": its update.sh says so in steps 3-5
    ( cd "$t/seed" &&
      awk '{print} /^after_pull\(\) \{$/{print "    echo NEW-SCRIPT"}' "$ROOT/setup/update.sh" > setup/update.sh &&
      echo "$1" >> Manifest.toml && g commit -qam "$1" && g push -q origin HEAD:main )
    git -C "$t/seed" rev-parse HEAD
}
run() { : > "$STEPS"; bash "$t/clone/setup/update.sh" "$@" 2>&1; }
head_is() { [[ "$(git -C "$t/clone" rev-parse HEAD)" == "$1" ]]; }

v2="$(new_release '# v2')"

# 1. --check: says what would change, changes nothing
out="$(run --check)"; rc=$?
[[ $rc -eq 0 && "$out" == *"1 commit(s) to pull"*"changes:  Manifest.toml"*"nothing was changed"* ]] && head_is "$v1" &&
    [[ ! -s "$STEPS" ]] && ok=1 || ok=0
report $ok "--check: reports the commit to pull and the new Manifest, changes nothing" "$out"

# 2. refusals: nothing pulled, no step run
git -C "$t/clone" switch -qc other
out="$(run)"; rc=$?
[[ $rc -ne 0 && "$out" == *"not main"* ]] && head_is "$v1" && [[ ! -s "$STEPS" ]] && ok=1 || ok=0
report $ok "refuses when the clone is not on main" "$out"
git -C "$t/clone" switch -q main; git -C "$t/clone" branch -qD other

echo "# edited" >> "$t/clone/Manifest.toml"
out="$(run)"; rc=$?
[[ $rc -ne 0 && "$out" == *"local changes"* ]] && head_is "$v1" && [[ ! -s "$STEPS" ]] && ok=1 || ok=0
report $ok "refuses when the clone has local changes" "$out"
git -C "$t/clone" checkout -q -- Manifest.toml

out="$(FAKE_JOBS='4242 run PENDING' run)"; rc=$?
[[ $rc -ne 0 && "$out" == *"4242 run PENDING"*"wait until"* ]] && head_is "$v1" && [[ ! -s "$STEPS" ]] && ok=1 || ok=0
report $ok "refuses while a job is queued, and lists it" "$out"

( cd "$t/clone" && echo x > local.txt && g add local.txt && g commit -qm local )
out="$(run)"; rc=$?
[[ $rc -ne 0 && "$out" == *"not on GitHub's main"* && ! -s "$STEPS" ]] && ok=1 || ok=0
report $ok "refuses when the clone has commits that are not on GitHub" "$out"
git -C "$t/clone" reset -q --hard "$v1"

# 3. an update: pulled, steps in order by the NEW script, log next to the depot
out="$(run)"; rc=$?
steps="$(paste -sd' ' "$STEPS")"
log="$(ls -t "$t/work/update_logs/"update_*.log 2>/dev/null | head -1)"   # newest: the refusals above logged too
[[ $rc -eq 0 && "$steps" == "install_julia setup setup_viz check_env" && "$out" == *NEW-SCRIPT*"Updated:"* ]] && head_is "$v2" &&
    [[ -n "$log" ]] && grep -q '== 2. Pull' "$log" && grep -q '== 5. Check' "$log" && ok=1 || ok=0
report $ok "update: pulls, then the new script runs install_julia, setup, setup_viz, check_env; one log" "$out
steps: $steps"

# 4. a failing step stops the update there
v3="$(new_release '# v3')"
out="$(FAIL_setup=1 run)"; rc=$?
steps="$(paste -sd' ' "$STEPS")"
[[ $rc -ne 0 && "$steps" == "install_julia setup" && "$out" == *"setup/setup.sh failed"* ]] && head_is "$v3" && ok=1 || ok=0
report $ok "stops at the first failing step (setup.sh): no viz, no check" "$out
steps: $steps"

# 5. run again after the fix: nothing to pull, all steps run
out="$(run)"; rc=$?
steps="$(paste -sd' ' "$STEPS")"
[[ $rc -eq 0 && "$steps" == "install_julia setup setup_viz check_env" && "$out" == *"0 commit(s) to pull"* ]] && ok=1 || ok=0
report $ok "rerun after a failure: nothing to pull, every step runs again" "$out"

(( fails == 0 )) && echo "All update.sh checks passed" || echo "$fails update.sh check(s) FAILED"
exit $(( fails > 0 ))

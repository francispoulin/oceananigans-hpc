#!/bin/bash
# Plotting job (movies, growth rates, ...) on an Alliance CPU node, with the viz environment.
# Submit FROM YOUR PROJECT FOLDER, after `ocean_setup` (it exports OCEAN_HPC_ROOT):
#
#     cd /path/to/BeaufortGyreSimulations
#     sbatch $OCEAN_HPC_ROOT/jobs/viz.sh scripts/make_movies.jl
#
# Each argument is one Julia command line, run in order; quote it if the script takes arguments:
#
#     sbatch $OCEAN_HPC_ROOT/jobs/viz.sh scripts/make_movies.jl "scripts/growth.jl run.toml"
#
# Override resources on the command line, e.g. sbatch --time=6:00:00 --mem=64G ...
# On pelee/rondeau (no Slurm) use tools/run_local.sh instead.
#SBATCH --job-name=viz
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=32000M
#SBATCH --time=3:00:00
#SBATCH --output=%x_%j.out

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
: "${OCEAN_HPC_ROOT:?run ocean_setup before sbatch, so the job knows where the repository is}"
[[ $# -gt 0 ]] || { echo "usage: sbatch jobs/viz.sh script.jl [\"script2.jl args\" ...]"; exit 1; }

cd "$SLURM_SUBMIT_DIR"
source "$OCEAN_HPC_ROOT/env/ocean_setup.sh"
set -eo pipefail          # after loading modules, as module commands can return harmless errors

for cmd in "$@"; do
    echo "== $(date '+%F %T')  julia --project=viz $cmd"
    # shellcheck disable=SC2086   # word splitting is intended: "script.jl arg1 arg2"
    julia --project="$OCEAN_HPC_ROOT/viz" $cmd
done
echo "== $(date '+%F %T')  done"

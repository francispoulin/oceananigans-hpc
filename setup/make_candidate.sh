#!/bin/bash
# A candidate environment for a library upgrade (ROADMAP.md, Phase 4), without touching the clone or
# its environment: a second worktree next to the clone (<clone>-candidate) at origin/main, with the
# named packages at the named versions (and, with --julia, a newer Julia), MPI configured for this
# machine, everything precompiled. On pelee/rondeau (or a login node: it needs internet):
#
#     bash setup/make_candidate.sh Oceananigans@0.116.1                  # one package
#     bash setup/make_candidate.sh --julia 1.13.2 Oceananigans@0.116.1   # and a newer Julia
#     bash setup/make_candidate.sh --push upgrade/oceananigans-0.116.1   # after its tests passed
#     bash setup/make_candidate.sh --clean                               # remove the worktree
#     bash setup/make_candidate.sh --base origin/<branch> ...            # start from a branch, not main
#
# Then test it where it is, with the candidate's own environment (about 10 minutes on pelee):
#
#     (source ../oceananigans-hpc-candidate/env/ocean_setup.sh && bash ../oceananigans-hpc-candidate/tools/run_tests.sh)
#
# Only Manifest.toml changes, with the packages named and what they need; with --julia also
# viz/Manifest.toml, whose plotting packages move to their newest compatible versions. The script
# prints every package whose version changed in Manifest.toml. --push commits those files in the candidate
# worktree and pushes them as a branch, so the same upgrade can be tested elsewhere
# (tools/test_branch.sh <branch>, e.g. in Trillium's debug queue) and opened as a pull request.
# Each new candidate starts again from origin/main; one candidate at a time.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -o pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    common="$(cd "$here" && cd "$(git rev-parse --git-common-dir)" && pwd)"
CLONE="$(dirname "$common")"
WT="${CANDIDATE_WORKTREE:-$CLONE-candidate}"
files=(Manifest.toml Project.toml viz/Manifest.toml viz/Project.toml)

julia_v=""; push=""; clean=0; pkgs=(); base="origin/main"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --julia) julia_v="${2:-}"; shift 2 ;;
        --push) push="${2:-}"; shift 2 ;;
        --clean) clean=1; shift ;;
        --base) base="${2:-}"; shift 2 ;;
        *@*) pkgs+=("$1"); shift ;;
        *) echo "unknown argument '$1' (packages are Name@version; try --help)"; exit 1 ;;
    esac
done
[[ -z "$julia_v" || "$julia_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "--julia needs a full version, e.g. 1.13.2"; exit 1; }

if [[ $clean -eq 1 ]]; then
    [[ -e "$WT" ]] || { echo "No candidate at $WT"; git -C "$CLONE" worktree prune; exit 0; }
    git -C "$CLONE" worktree remove --force "$WT" && git -C "$CLONE" worktree prune && echo "Removed $WT"
    exit $?
fi

if [[ -n "$push" ]]; then
    [[ -d "$WT" ]] || { echo "No candidate at $WT: make one first"; exit 1; }
    [[ -n "$(git -C "$WT" status --porcelain -- "${files[@]}")" ]] || { echo "The candidate changes nothing; nothing to push"; exit 1; }
    git -C "$WT" config user.name >/dev/null || { echo "Set git's user.name and user.email first (git config --global ...)"; exit 1; }
    msg="Candidate upgrade: $(head -1 "$WT/.candidate" 2>/dev/null)"
    git -C "$WT" add -- "${files[@]}" &&
    git -C "$WT" commit -q -m "$msg" -m "Made with setup/make_candidate.sh on $(hostname -s). Versions that changed:" \
        -m "$(tail -n +2 "$WT/.candidate" 2>/dev/null)" &&
    git -C "$WT" push -q origin "HEAD:refs/heads/$push" &&
    echo "Pushed: branch $push ($(git -C "$WT" rev-parse --short HEAD))" &&
    echo "Test it elsewhere with: bash tools/test_branch.sh $push"
    exit $?
fi

[[ ${#pkgs[@]} -gt 0 || -n "$julia_v" ]] || { echo "usage: make_candidate.sh [--julia X.Y.Z] Package@version ...   (or --push <branch>, --clean)"; exit 1; }

echo "== Worktree $WT -> $base"
git -C "$CLONE" fetch --quiet origin || { echo "git fetch failed"; exit 1; }
git -C "$CLONE" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "no commit '$base' (after git fetch)"; exit 1; }
git -C "$CLONE" worktree prune
if [[ -e "$WT" ]]; then
    [[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] ||
        { echo "$WT has an earlier candidate (changed files). Push it or remove it first: bash $0 --clean"; exit 1; }
    git -C "$WT" checkout --quiet --detach "$base" || exit 1
else
    git -C "$CLONE" worktree add --quiet --detach "$WT" "$base" || exit 1
fi
echo "   $(git -C "$WT" describe --tags --always) ($(git -C "$WT" log -1 --format='%h %s'))"

set +u
source "$WT/env/ocean_setup.sh" >/dev/null || exit 1
old="$(mktemp)"; new="$(mktemp)"; trap 'rm -f "$old" "$new"' EXIT
J="$(command -v julia)"
# name version, one line per package of a Manifest (and the Julia version first)
listing='using TOML; m = TOML.parsefile(ARGS[1]); println("julia ", m["julia_version"]);
         for k in sort!(collect(keys(m["deps"]))); println(k, " ", get(m["deps"][k][1], "version", "stdlib")); end'
"$J" --startup-file=no -e "$listing" "$WT/Manifest.toml" > "$old" || exit 1

if [[ -n "$julia_v" ]]; then
    echo "== Julia $julia_v"
    bash "$here/install_julia.sh" "$julia_v" || exit 1      # this script's copy: it takes a version
    J="$OCEAN_SOFTWARE_DIR/julia-$julia_v/bin/julia"
fi

echo "== Packages ($J)"
adds=""
for p in "${pkgs[@]}"; do adds+="Pkg.add(PackageSpec(name=\"${p%@*}\", version=\"${p#*@}\")); "; done
# Pkg is loaded outside the project, then the project activated: with a Manifest made by an older
# Julia active, a newer Julia cannot use its own precompiled standard libraries (their dependencies
# differ) and recompiles them (Julia 1.13.2: Markdown overflows the stack, Oct 24). After the
# resolve, the Manifest is the new Julia's.
# The registry is updated first, in a process of its own.
"$J" --startup-file=no -e 'using Pkg; Pkg.Registry.update()' || exit 1
# Resolve (Pkg.add resolves) and instantiate in separate processes. With Julia 1.13.2 the resolve
# writes the new Manifest and then fails while installing ("Unknown package: ChunkCodecLibZstd",
# whose dependency Zstd_jll became part of Julia), whereas instantiate in a new process works
# (Oct 24). So an error from the resolve step is reported but not fatal: the new process's
# instantiate decides, and the requested versions are checked in the Manifest afterwards.
for env in "$WT" ${julia_v:+"$WT/viz"}; do
    # The packages asked for; for viz/ (plotting only) with a new Julia, everything it holds moves to
    # the newest compatible versions: a plain resolve keeps the old Julia's standard-library
    # versions, which the new Julia refuses ("Statistics ... restricted to versions 1.10.0", Oct 24).
    if [[ "$env" == "$WT" && -n "$adds" ]]; then step="$adds"; else step="Pkg.update()"; fi
    "$J" --startup-file=no -e "using Pkg; Pkg.activate(ARGS[1]); $step" "$env" ||
        echo "   (the resolve step ended with an error; continuing with instantiate in a new process)"
    "$J" --startup-file=no -e 'using Pkg; Pkg.activate(ARGS[1]); Pkg.instantiate()' "$env" || exit 1
done
for p in "${pkgs[@]}"; do
    "$J" --startup-file=no -e 'using TOML; m = TOML.parsefile(ARGS[1])["deps"];
        haskey(m, ARGS[2]) && m[ARGS[2]][1]["version"] == ARGS[3] || (println("$(ARGS[2]) is not at $(ARGS[3]) in the Manifest"); exit(1))' \
        "$WT/Manifest.toml" "${p%@*}" "${p#*@}" || exit 1
done
if [[ -n "$julia_v" ]]; then
    for m in "$WT/Manifest.toml" "$WT/viz/Manifest.toml"; do
        grep -q "^julia_version = \"$julia_v\"$" "$m" || { echo "$m is not for Julia $julia_v"; exit 1; }
    done
fi

echo "== MPI for this machine, then precompile (with the candidate's own environment)"
bash "$WT/setup/configure_mpi.sh" "$WT" > "$WT/.candidate_mpi.log" 2>&1 ||
    { echo "configure_mpi.sh failed: see $WT/.candidate_mpi.log"; exit 1; }
( source "$WT/env/ocean_setup.sh" >/dev/null &&
  julia --project="$WT" -e 'using Pkg; Pkg.precompile()' &&
  julia --project="$WT/viz" -e 'using Pkg; Pkg.precompile()' ) || exit 1

"$J" --startup-file=no -e "$listing" "$WT/Manifest.toml" > "$new" || exit 1
{ echo "${pkgs[*]}${julia_v:+ julia@$julia_v}"
  join -a1 -a2 -e '(none)' -o 0,1.2,2.2 <(sort "$old") <(sort "$new") | awk '$2 != $3 {print "  " $1 ": " $2 " -> " $3}'
} > "$WT/.candidate"
echo
echo "Candidate ready in $WT. Versions that changed:"
tail -n +2 "$WT/.candidate"
echo
echo "Test it here (about 10 minutes on pelee):"
echo "    (source $WT/env/ocean_setup.sh && bash $WT/tools/run_tests.sh)"
echo "If it passes: bash $0 --push upgrade/<name>"

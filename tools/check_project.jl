# Checks one Julia project folder; tools/check_env.sh runs it for you (use that instead):
#
#     julia --startup-file=no tools/check_project.jl /path/to/project
#
# Uses only the standard library and loads no packages, so it is quick and safe on a login node.
# Exit code = number of warnings.

if any(in(("-h", "--help")), ARGS)      # -h: print the comments above and stop
    for line in eachline(@__FILE__)
        startswith(line, "#") || break
        println(replace(line, r"^# ?" => ""))
    end
    exit(0)
end

using TOML

const project = abspath(get(ARGS, 1, "."))
const mpiroot = get(ENV, "OCEAN_MPI_ROOT", "")
const vizdir  = joinpath(get(ENV, "OCEAN_HPC_ROOT", ""), "viz")
nwarn = 0
ok(s)   = println("  \e[32mOK\e[0m    ", s)
warn(s) = (global nwarn += 1; println("  \e[33mWARN\e[0m  ", s))
info(s) = println("        ", s)

readtoml(f) = isfile(f) ? TOML.parsefile(f) : nothing

proj = readtoml(joinpath(project, "Project.toml"))
if proj === nothing
    warn("no Project.toml here. Wrong folder? `julia --project=.` would create a new, empty project.")
    exit(nwarn)
end
deps = sort(collect(keys(get(proj, "deps", Dict()))))
ok("Project.toml: " * (isempty(deps) ? "no packages" : join(deps, ", ")))

manifest = readtoml(joinpath(project, "Manifest.toml"))
if manifest === nothing
    warn("no Manifest.toml: run `julia --project=. -e 'using Pkg; Pkg.instantiate()'` (login node)")
else
    mv = get(manifest, "julia_version", "?")
    if mv == string(VERSION)
        ok("Manifest made with this Julia ($mv)")
    elseif startswith(mv, "$(VERSION.major).$(VERSION.minor).")
        info("Manifest made with Julia $mv, running $VERSION: same series, usually fine")
    else
        warn("Manifest made with Julia $mv but running $VERSION: expect re-resolution or errors")
    end
end

is_viz = isdir(vizdir) && samefile(project, vizdir)
if !is_viz && any(d -> occursin("Makie", d), deps)
    info("this project has Makie ($(join(filter(d -> occursin("Makie", d), deps), ", "))). " *
         "Plotting can use viz/ instead, so simulation jobs don't load it.")
end

# MPI setup: only relevant if the project uses MPI (directly or through Oceananigans).
uses_mpi = any(in(deps), ("MPI", "Oceananigans", "NumericalEarth"))
prefs = readtoml(joinpath(project, "LocalPreferences.toml"))
if uses_mpi
    if prefs === nothing
        warn("no LocalPreferences.toml: MPI.jl will use its own MPI. Run once on this machine:")
        info("bash \$OCEAN_HPC_ROOT/setup/configure_mpi.sh $project")
    else
        mp  = get(prefs, "MPIPreferences", Dict())
        lib = get(get(prefs, "OpenMPI_jll", Dict()), "libmpi_path", "")
        binary = get(mp, "binary", "(not set)")
        binary == "system" ? ok("MPI.jl uses the system MPI") :
                             warn("MPIPreferences binary = $binary (expected \"system\")")
        if isempty(lib)
            warn("OpenMPI_jll not redirected (NetCDF output + MPI may crash at MPI.Init)")
        elseif !isempty(mpiroot) && !startswith(lib, mpiroot)
            warn("OpenMPI_jll -> $lib, which is not this machine's MPI ($mpiroot).")
            info("LocalPreferences.toml was probably made on another machine: rerun configure_mpi.sh here.")
        else
            ok("OpenMPI_jll -> $lib")
        end
    end
end

# Packages in the global environment (@v1.13) are visible to EVERY project, so a script can
# work only because of them, then fail on another machine or for another user.
# The main depot is the last entry: Trillium jobs put a writable copy of the compiled files first.
depot = last(filter(!isempty, split(get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia")), ':')))
globalproj = readtoml(joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml"))
globaldeps = globalproj === nothing ? String[] : sort(collect(keys(get(globalproj, "deps", Dict()))))
if isempty(globaldeps)
    ok("global environment @v$(VERSION.major).$(VERSION.minor) is empty")
else
    warn("global environment @v$(VERSION.major).$(VERSION.minor) has: $(join(globaldeps, ", ")). " *
         "Every project can load these, which hides missing dependencies.")
    info("Remove with: julia --project=@v$(VERSION.major).$(VERSION.minor) -e 'using Pkg; Pkg.rm([$(join(repr.(globaldeps), ", "))])'")
end

# viz/ is set up when the CairoMakie that viz/Manifest.toml names is in the depot: after a platform
# update with a new viz/Manifest.toml, an older CairoMakie left in the depot does not count (it did
# until v1.3.0, so check_env said "set up" before setup_viz.sh had run). Packages are stored under
# packages/<name>/<slug>, the slug made from the package's UUID and tree hash, as Pkg does.
function viz_installed()
    vm = readtoml(joinpath(vizdir, "Manifest.toml"))
    vm === nothing && return false
    any_cairomakie = isdir(joinpath(depot, "packages", "CairoMakie"))
    entries = get(get(vm, "deps", Dict()), "CairoMakie", nothing)
    entries === nothing && return any_cairomakie
    e = first(entries)
    try
        slug = Base.version_slug(Base.UUID(e["uuid"]), Base.SHA1(e["git-tree-sha1"]))
        return isdir(joinpath(depot, "packages", "CairoMakie", slug))
    catch                     # an internal of Base: if it changes, fall back to the simpler check
        return any_cairomakie
    end
end

if !is_viz
    installed = viz_installed()
    if !isdir(vizdir)
        info("viz/ not found in the repository")
    elseif !installed
        warn("viz/ not set up on this machine: bash \$OCEAN_HPC_ROOT/setup/setup_viz.sh")
    else
        ok("viz/ is set up (plot with julia --project=\$OCEAN_HPC_ROOT/viz ...)")
    end
end

exit(nwarn)

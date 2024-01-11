module Apps

using Pkg
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, handle_repo_add!, write_manifest, write_project
using Pkg.Operations: print_single, source_path
using Pkg.API: handle_package_input!
using TOML, UUIDs
import Pkg.Registry

#############
# Constants #
#############

const APP_ENV_FOLDER = joinpath(homedir(), ".julia", "environments", "apps")
const APP_MANIFEST_FILE = joinpath(APP_ENV_FOLDER, "AppManifest.toml")
const JULIA_BIN_PATH = joinpath(homedir(), ".julia", "bin")

##################
# Helper Methods #
##################

function create_temp_environment()
    tempenv = mktempdir()
    mkpath(tempenv)
    # TODO restore.
    Pkg.activate(tempenv)
    return tempenv
end

function handle_project_file(sourcepath)
    project_file = joinpath(sourcepath, "Project.toml")
    isfile(project_file) || error("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && error("No apps found in Project.toml for package $(project.name) at version $(project.version)")
    return project
end

function move_environment(tempenv, pkgname)
    mkpath(APP_ENV_FOLDER)
    # TODO: remove force
    mv(tempenv, joinpath(APP_ENV_FOLDER, pkgname); force=true)
end

function update_app_manifest(pkg)
    manifest = Pkg.Types.read_manifest(APP_MANIFEST_FILE)
    manifest.deps[pkg.uuid] = pkg
    write_manifest(manifest, APP_MANIFEST_FILE)
end


#=
# Can be:

# name + version -> registry -> repo + git-tree-sha1 -> pkgserver or git
# name + branch -> registry -> repo -> git
# url + [branch] -> git



function download_package(pkg::PackageSpec, manifest, manifest_file)
    repo_source = pkg.repo.source
    new_download = false
    if repo_source !== nothing
        # TODO: Update io
        new_download = handle_repos_add!(pkg::PackageSpec, manifest, manifest_file, nothing, stdout)
    end
end
=#

app_context() = Context(env=EnvCache(joinpath(APP_ENV_FOLDER, "Project.toml")))

##################
# Main Functions #
##################

function add(pkg::String)
    pkg = PackageSpec(pkg)
    add(pkg)
end

function add(pkg::PackageSpec)
    handle_package_input!(pkg)

    ctx = app_context()

    if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
        entry = Pkg.API.manifest_info(ctx.env.manifest, pkg.uuid)
        pkg = Pkg.Operations.update_package_add(ctx, pkg, entry, false)
        new = handle_repo_add!(ctx, pkg)
    else
        pkgs = [pkg]
        Pkg.Operations.registry_resolve!(ctx.registries, pkgs)
        Pkg.Operations.ensure_resolved(ctx, ctx.env.manifest, pkgs, registry=true)

        # Get the latest version from registry...
        max_v = nothing
        tree_hash = nothing
        for reg in ctx.registries
            if get(reg, pkg.uuid, nothing) !== nothing
                reg_pkg = get(reg, pkg.uuid, nothing)
                reg_pkg === nothing && continue
                pkg_info = Registry.registry_info(reg_pkg)
                for (version, info) in pkg_info.version_info
                    info.yanked && continue
                    if pkg.version isa VersionNumber
                        pkg.version == version || continue
                    else
                        version in pkg.version || continue
                    end
                    if max_v === nothing || version > max_v
                        max_v = version
                        tree_hash = info.git_tree_sha1
                    end
                end
            end
        end
        if max_v === nothing
            error("Suitable package version for $(pkg.name) not found in any registries.")
        end
        pkg.version = max_v
        pkg.tree_hash = tree_hash

        new_apply = Pkg.Operations.download_source(ctx, pkgs)
    end

    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = handle_project_file(sourcepath)


    # TODO: Type stab
    #appdeps = get(project, "appdeps", Dict())
    # merge!(project.deps, appdeps)
    project.path = sourcepath

    projectfile = joinpath(APP_ENV_FOLDER, pkg.name, "Project.toml")
    mkpath(dirname(projectfile))
    write_project(project, projectfile)

    # Move manifest if it exists here.


    Pkg.activate(joinpath(APP_ENV_FOLDER, pkg.name))
    Pkg.instantiate()

    # TODO: Call build on the package if it was freshly installed?

    # Create the new package env.
    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
    update_app_manifest(pkg)
    generate_shims_for_apps(pkg.name, project.apps, dirname(dirname(sourcepath)))
end


function develop(pkg::String)
    develop(PackageSpec(pkg))
end

function develop(pkg::PackageSpec)
    # TODO, this should just download the package and instantiate its environment,
    # not create a new environment.
    tempenv = create_temp_environment()
    Pkg.develop(pkg)

    ctx = Context()
    uuid = first(ctx.env.project.deps).second
    pkg = ctx.env.manifest.deps[uuid]

    sourcepath = Base.find_package(pkg.name)
    project = handle_project_file(sourcepath)

    pkg.apps = project.apps
    update_app_manifest(pkg)
    generate_shims_for_apps(pkg.name, project.apps, dirname(dirname(sourcepath)))
end

function status()
    manifest = Pkg.Types.read_manifest(joinpath(APP_ENV_FOLDER, "AppManifest.toml"))
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        info = manifest.deps[dep.uuid]
        printstyled("[", string(dep.uuid)[1:8], "] "; color = :light_black)
        print_single(stdout, dep)
        single_app = length(info.apps) == 1
        if !single_app
            println()
        else
            print(":")
        end
        for (appname, appinfo) in info.apps
            printstyled("  $(appname) $(appinfo.julia_command) \n", color=:green)
        end
    end
end

function free()

end

function rm(pkg_or_app)
    manifest = Pkg.Types.read_manifest(joinpath(APP_ENV_FOLDER, "AppManifest.toml"))
    dep_idx = findfirst(dep -> dep.name == pkg_or_app, manifest.deps)
    if dep_idx !== nothing
        dep = manifest.deps[dep_idx]
        @info "Deleted all apps for package $(dep.name)"
        delete!(manifest.deps, dep.uuid)
        for (appname, appinfo) in dep.apps
            @info "Deleted $(appname)"
            Base.rm(joinpath(JULIA_BIN_PATH, appname); force=true)
        end
        Base.rm(joinpath(APP_ENV_FOLDER, dep.name); recursive=true)
    else
        for (uuid, pkg) in manifest.deps
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            if app_idx !== nothing
                app = pkg.apps[app_idx]
                @info "Deleted app $(app.name)"
                delete!(pkg.apps, app.name)
                Base.rm(joinpath(JULIA_BIN_PATH, app.name); force=true)
            end
            if isempty(pkg.apps)
                delete!(manifest.deps, uuid)
                Base.rm(joinpath(APP_ENV_FOLDER, pkg.name); recursive=true)
            end
        end
    end

    Pkg.Types.write_manifest(manifest, APP_MANIFEST_FILE)
    return
end



#########
# Shims #
#########

function generate_shims_for_apps(pkgname, apps, env)
    for (_, app) in apps
        generate_shim(app, pkgname; env)
    end
end

function generate_shim(app::AppInfo, pkgname; julia_executable_path::String=joinpath(Sys.BINDIR, "julia"), env=joinpath(homedir(), ".julia", "environments", "apps", pkgname))
    filename = joinpath(homedir(), ".julia", "bin", app.name * (Sys.iswindows() ? ".bat" : ""))
    mkpath(dirname(filename))
    content = if Sys.iswindows()
        windows_shim(pkgname, julia_executable_path, env)
    else
        bash_shim(pkgname, julia_executable_path, env)
    end
    open(filename, "w") do f
        write(f, content)
    end
    if Sys.isunix()
        chmod(filename, 0o755)
    end
end


function bash_shim(pkgname, julia_executable_path::String, env)
    return """
        #!/usr/bin/env bash

        export JULIA_LOAD_PATH=$(repr(env))
        exec $julia_executable_path \\
            --startup-file=no \\
            -m $(pkgname) \\
            "\$@"
        """
end

function windows_shim(pkgname, julia_executable_path::String, env)
    return """
        @echo off
        set JULIA_LOAD_PATH=$(repr(env))

        $julia_executable_path ^
            --startup-file=no ^
            -m $(pkgname) ^
            %*
        """
end




#################
# PATH handling #
#################

function add_bindir_to_path()
    if Sys.iswindows()
        modify_windows_path()
    else
        modify_unix_path()
    end
end

function get_shell_config_file(home_dir, julia_bin_path)
    # Check for various shell configuration files
    if occursin("/zsh", ENV["SHELL"])
        return (joinpath(home_dir, ".zshrc"), "path=('$julia_bin_path' \$path)\nexport PATH")
    elseif occursin("/bash", ENV["SHELL"])
        return (joinpath(home_dir, ".bashrc"), "export PATH=\"\$PATH:$julia_bin_path\"")
    elseif occursin("/fish", ENV["SHELL"])
        return (joinpath(home_dir, ".config/fish/config.fish"), "set -gx PATH \$PATH $julia_bin_path")
    elseif occursin("/ksh", ENV["SHELL"])
        return (joinpath(home_dir, ".kshrc"), "export PATH=\"\$PATH:$julia_bin_path\"")
    elseif occursin("/tcsh", ENV["SHELL"]) || occursin("/csh", ENV["SHELL"])
        return (joinpath(home_dir, ".tcshrc"), "setenv PATH \$PATH:$julia_bin_path") # or .cshrc
    else
        return (nothing, nothing)
    end
end

function modify_unix_path()
    home_dir = ENV["HOME"]
    julia_bin_path = joinpath(home_dir, ".julia/bin")

    shell_config_file, path_command = get_shell_config_file(home_dir, julia_bin_path)
    if shell_config_file === nothing
        @warn "Failed to insert `.julia/bin` to PATH: Failed to detect shell"
        return
    end

    if !isfile(shell_config_file)
        @warn "Failed to insert `.julia/bin` to PATH: $(repr(shell_config_file)) does not exist."
        return
    end
    file_contents = read(shell_config_file, String)

    # Check for the comment fence
    start_fence = "# >>> julia apps initialize >>>"
    end_fence = "# <<< julia apps initialize <<<"
    fence_exists = occursin(start_fence, file_contents) && occursin(end_fence, file_contents)

    if !fence_exists
        open(shell_config_file, "a") do file
            print(file, "\n$start_fence\n\n")
            print(file, "# !! Contents within this block are managed by Julia's package manager Pkg !!\n\n")
            print(file, "$path_command\n\n")
            print(file, "$end_fence\n\n")
        end
        @debug "added Julia bin path to $shell_config_file."
    end
end

function modify_windows_path()
    julia_bin_path = joinpath(ENV["HOMEPATH"], ".julia/bin")

    # Get current PATH
    current_path = ENV["PATH"]

    # Check if .julia/bin is already in PATH
    if occursin(julia_bin_path, current_path)
        return
    end

    # Add .julia/bin to PATH
    new_path = current_path * ";" * julia_bin_path
    run(`setx PATH "$new_path"`)

    println("Updated PATH with Julia bin path.")
end

end

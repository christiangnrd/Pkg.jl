module Apps

using Pkg
using Pkg.Types: AppInfo, PackageSpec, Context
using TOML, UUIDs

#############
# Constants #
#############

const APP_ENV_FOLDER = joinpath(homedir(), ".julia", "environments", "apps")
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
    project_file = joinpath(dirname(dirname(sourcepath)), "Project.toml")
    isfile(project_file) || error("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && error("No apps found in Project.toml")
    return project
end

function move_environment(tempenv, pkgname)
    mkpath(APP_ENV_FOLDER)
    # TODO: remove force
    mv(tempenv, joinpath(APP_ENV_FOLDER, pkgname); force=true)
end

function write_app_manifest(pkg)
    app_manifest_path = joinpath(APP_ENV_FOLDER, "AppManifest.toml")
    manifest = Pkg.Types.read_manifest(app_manifest_path)

    manifest.deps[pkg.uuid] = pkg

    @show pkg.apps

    mktemp() do tmpfile, io
        Pkg.Types.write_manifest(io, manifest)
        close(io)
        mv(tmpfile, app_manifest_path; force=true)
    end
end



##################
# Main Functions #
##################

function add(pkg::String)
    add(PackageSpec(pkg))
end

function add(pkg::PackageSpec)
    tempenv = create_temp_environment()
    Pkg.add(pkg)

    ctx = Context()
    uuid = first(ctx.env.project.deps).second
    pkg = ctx.env.manifest.deps[uuid]

    sourcepath = Base.find_package(pkg.name)
    project = handle_project_file(sourcepath)

    pkg.apps = project.apps

    move_environment(tempenv, pkg.name)
    write_app_manifest(pkg)
    generate_shims_for_apps(pkg.name, project.apps)
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
    write_app_manifest(pkg)
    generate_shims_for_apps(pkg.name, project.apps, dirname(dirname(sourcepath)))
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

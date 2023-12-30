module Apps

using ..Pkg
import ..Pkg.Types: AppInfo, PackageSpec, Context

using TOML, UUIDs


#######
# API #
#######


add(pkg::String) = add(PackageSpec(pkg))

function add(pkg::PackageSpec)
    tempenv = mktempdir()
    mkpath(tempenv)
    Pkg.activate(tempenv) do
        Pkg.add(pkg)

        ctx = Context()
        uuid = first(ctx.env.project.deps).second
        pkg = ctx.env.manifest.deps[uuid]

        sourcepath = Base.find_package(pkg.name)

        project_file = joinpath(dirname(dirname(sourcepath)), "Project.toml")
        if !isfile(project_file)
            error("Project file not found: $project_file")
        end

        project = Pkg.Types.read_project(project_file)
        if isempty(project.apps)
            error("No apps found in Project.toml")
        end

        app_env_folder = joinpath(homedir(), ".julia", "environments", "apps")
        mkpath(app_env_folder)
        mv(tempenv, joinpath(app_env_folder, pkg.name))

        write_app_manifest(pkg)
        # Create project

        for (_, app) in project.apps
            # @info "Generating shim... for app $(app.name)"
            generate_shim(pkg.name, app)
        end
    end
end

# rm, should remove environment and all apps


function write_app_manifest(pkg)
    # PidLock
    app_manifest_path = joinpath(homedir(), ".julia", "environments", "apps", "AppManifest.toml")

    manifest = Pkg.Types.read_manifest(app_manifest_path)

    manifest.deps[pkg.uuid] = pkg

    mktemp() do tmpfile, io
        Pkg.Types.write_manifest(io, manifest)
        close(io)
        # TODO: Remove
        mv(tmpfile, app_manifest_path; force=true)
    end
end


#########
# Shims #
#########

function generate_shim(env, app::AppInfo, julia_executable_path::String=joinpath(Sys.BINDIR, "julia"))
    if Sys.iswindows()
        generate_windows_shim(env, app, julia_executable_path)
    else
        generate_bash_shim(env, app, julia_executable_path)
    end
end


function generate_bash_shim(pkgname, app, julia_executable_path::String)
    filename = joinpath(homedir(), ".julia", "bin", app.name)
    appcommand = app.command === nothing ? "" : app.command
    mkpath(dirname(filename))
    script = """
    #!/usr/bin/env bash
    julia_executable=$julia_executable_path

    # Check if julia_executable_path exists, if not, fall back to 'julia'
    if [ ! -x "\$julia_executable" ]; then
        # TODO: More actionable error message
        echo "Warning: Julia executable not found at $julia_executable_path, falling back to 'julia'."
        julia_executable="julia"
    fi

    julia_args=()
    app_args=()
    sep_found=false

    # First pass to check for --
    for arg in "\$@"; do
        if [ "\$arg" = "--" ]; then
            sep_found=true
            break
        fi
    done

    # Depending on the presence of --, split the arguments
    if [ "\$sep_found" = true ]; then
        collecting_julia_args=true
        for arg in "\$@"; do
            if [ "\$arg" = "--" ]; then
                collecting_julia_args=false
                continue
            fi
            if [ "\$collecting_julia_args" = true ]; then
                julia_args+=("\$arg")
            else
                app_args+=("\$arg")
            fi
        done
    else
        app_args=("\$@")
    fi

    JULIA_LOAD_PATH=$(homedir)/.julia/environments/apps/$(pkgname)
    exec $julia_executable_path \\
        --startup-file=no \\
        $(appcommand) \\
        "\${julia_args[@]}" \\
        -m $(pkgname) \\
        "\${app_args[@]}"
    """
    open(filename, "w") do f
        write(f, script)
    end
    chmod(filename, 0o755)  # Set execute permissions
end

function generate_windows_shim(pkgname, app, julia_executable_path::String)
    filename = joinpath(homedir(), ".julia", "bin", "$(app.name).bat")
    appcommand = app.command === nothing ? "" : app.command
    mkpath(dirname(filename))
    script = """
        @echo off
        set julia_executable=$julia_executable_path

        rem Check if julia_executable_path exists, if not, fall back to 'julia'
        if not exist "%julia_executable%" (
            echo Warning: Julia executable not found at $julia_executable_path, falling back to 'julia'
            set julia_executable=julia
        )

        setlocal enabledelayedexpansion
        set "julia_args="
        set "app_args="
        set "sep_found=false"

        :arg_loop
        if "%~1"=="" goto end_arg_loop
        if "%~1"=="--" set "sep_found=true" & shift & goto arg_loop
        if "!sep_found!"=="false" (
            set "julia_args=!julia_args! %~1"
        ) else (
            set "app_args=!app_args! %~1"
        )
        shift
        goto arg_loop
        :end_arg_loop

        set JULIA_LOAD_PATH=%HOMEDRIVE%%HOMEPATH%\\.julia\\environments\\apps\\$(pkg.name)

        $julia_executable_path ^
            --startup-file=no ^
            $(appcommand) ^
            !julia_args! ^
            -m $(pkgname) ^
            !app_args!
    """
    open(filename, "w") do f
        write(f, script)
    end
    println("Generated Windows shim for: ", app.name)
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

// Env.pmod — environment and run commands: cmd_env, build_paths, cmd_run.
// All state is passed via context mapping (ctx).

inherit .Config;
inherit .Helpers;
inherit .Manifest;

//! Build module + include paths from project root and global dir.
array(array(string)) build_paths(mapping ctx) {
    array(string) mod_paths = ({});
    array(string) inc_paths = ({});

    string project_root = find_project_root() || getcwd();
    string pr_modules = combine_path(project_root, "modules");
    if (Stdio.is_dir(pr_modules)) {
        mod_paths += ({ pr_modules });
        // Check for .h files
        mapping r = Process.run(
            ({"find", pr_modules, "-name", "*.h", "-print", "-quit"}));
        if (r->exitcode == 0 && sizeof(r->stdout) > 0)
            inc_paths += ({ pr_modules });
    }

    // Local deps from pike.json
    string pjson = combine_path(project_root, "pike.json");
    if (Stdio.exist(pjson)) {
        foreach (parse_deps(pjson); ; array(string) dep) {
            if (has_prefix(dep[1], "./") || has_prefix(dep[1], "/")) {
                string lpath = dep[1];
                if (has_prefix(lpath, "./"))
                    lpath = combine_path(project_root, lpath);
                if (!Stdio.is_dir(lpath)) continue;
                mod_paths += ({ lpath });
                mapping r = Process.run(
                    ({"find", lpath, "-name", "*.h",
                      "-print", "-quit"}));
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    inc_paths += ({ lpath });
            }
        }
    }

    if (Stdio.is_dir(ctx["global_dir"])) {
        mod_paths += ({ ctx["global_dir"] });
        mapping r = Process.run(
            ({"find", ctx["global_dir"], "-name", "*.h",
              "-print", "-quit"}));
        if (r->exitcode == 0 && sizeof(r->stdout) > 0)
            inc_paths += ({ ctx["global_dir"] });
    }

    return ({ mod_paths, inc_paths });
}

void cmd_run(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    if (sizeof(rest) == 0)
        die("usage: pmp run <script.pike> [args...]");

    string script = rest[0];
    array(string) script_args = rest[1..];

    array(array(string)) paths = build_paths(ctx);
    array(string) mod_paths = paths[0];
    array(string) inc_paths = paths[1];

    array(string) env_vars = ({});
    if (sizeof(mod_paths) > 0) {
        string existing = getenv("PIKE_MODULE_PATH") || "";
        string new_path = mod_paths * ":";
        if (sizeof(existing) > 0) new_path += ":" + existing;
        env_vars += ({"PIKE_MODULE_PATH=" + new_path});
    }
    if (sizeof(inc_paths) > 0) {
        string existing = getenv("PIKE_INCLUDE_PATH") || "";
        string new_path = inc_paths * ":";
        if (sizeof(existing) > 0) new_path += ":" + existing;
        env_vars += ({"PIKE_INCLUDE_PATH=" + new_path});
    }

    if (sizeof(env_vars) > 0) {
        // Build environment map from current env + overrides
        mapping(string:string) env = getenv() || ([]);
        foreach (env_vars; ; string var) {
            array parts = var / "=";
            if (sizeof(parts) >= 2)
                env[parts[0]] = parts[1..] * "=";
        }
        Process.exece(ctx["pike_bin"],
            ({ ctx["pike_bin"], script, @script_args }), env);
    } else {
        Process.exec(ctx["pike_bin"], script, @script_args);
    }
}

void cmd_env(mapping ctx) {
    string env_dir = ".pike-env";
    string env_bin = combine_path(env_dir, "bin");
    string project_root = find_project_root() || getcwd();
    string abs_env_dir = combine_path(getcwd(), env_dir);

    if (Stdio.is_dir(env_dir))
        info(".pike-env/ already exists — recreating");

    Stdio.mkdirhier(env_bin);

    // .pike-env/.gitignore — don't track generated files
    Stdio.write_file(combine_path(env_dir, ".gitignore"), "*\n");

    // pike-env.cfg — metadata (single source of truth for wrapper)
    string cfg = sprintf(
        "pike_bin = %s\n"
        "project_root = %s\n"
        "pmp_version = %s\n",
        ctx["pike_bin"], project_root, PMP_VERSION);
    Stdio.write_file(combine_path(env_dir, "pike-env.cfg"), cfg);

    // Resolve local dep paths from pike.json at generation time
    array(string) local_mod_paths = ({});
    array(string) local_inc_paths = ({});
    string pjson = combine_path(project_root, "pike.json");
    if (Stdio.exist(pjson)) {
        foreach (parse_deps(pjson); ; array(string) dep) {
            if (has_prefix(dep[1], "./") || has_prefix(dep[1], "/")) {
                string lpath = dep[1];
                if (has_prefix(lpath, "./"))
                    lpath = combine_path(project_root, lpath);
                if (!Stdio.is_dir(lpath)) continue;
                local_mod_paths += ({ lpath });
                mapping r = Process.run(
                    ({"find", lpath, "-name", "*.h",
                      "-print", "-quit"}));
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    local_inc_paths += ({ lpath });
            }
        }
    }

    // bin/pike — wrapper that sets PIKE_MODULE_PATH / PIKE_INCLUDE_PATH
    string local_mod_block = "";
    foreach (local_mod_paths; ; string p)
        local_mod_block += "MOD_PATHS=\"${MOD_PATHS:+$MOD_PATHS:}" + p + "\"\n";
    string local_inc_block = "";
    foreach (local_inc_paths; ; string p)
        local_inc_block += "INC_PATHS=\"${INC_PATHS:+$INC_PATHS:}" + p + "\"\n";

    string wrapper =
        "#!/bin/sh\n"
        "# Generated by pmp env. Re-run 'pmp env' to update.\n"
        "set -e\n"
        "\n"
        "# Read config\n"
        "_env_dir=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\n"
        "_cfg=\"$_env_dir/pike-env.cfg\"\n"
        "PIKE_BIN=\"$(sed -n 's/^pike_bin = //p' \"$_cfg\")\"\n"
        "PROJECT_ROOT=\"$(sed -n 's/^project_root = //p' \"$_cfg\")\"\n"
        "GLOBAL_DIR=\"$HOME/.pike/modules\"\n"
        "\n"
        "MOD_PATHS=\"\"\n"
        "INC_PATHS=\"\"\n"
        "\n"
        "# Project modules\n"
        "if [ -d \"$PROJECT_ROOT/modules\" ]; then\n"
        "  MOD_PATHS=\"$PROJECT_ROOT/modules\"\n"
        "  if find \"$PROJECT_ROOT/modules\" -name '*.h' -print -quit 2>/dev/null | grep -q .; then\n"
        "    INC_PATHS=\"$PROJECT_ROOT/modules\"\n"
        "  fi\n"
        "fi\n"
        "\n";

    if (sizeof(local_mod_paths) > 0)
        wrapper += "# Local dependencies (resolved from pike.json)\n"
            + local_mod_block + local_inc_block + "\n";

    wrapper +=
        "# Global modules\n"
        "if [ -d \"$GLOBAL_DIR\" ]; then\n"
        "  MOD_PATHS=\"${MOD_PATHS:+$MOD_PATHS:}$GLOBAL_DIR\"\n"
        "fi\n"
        "\n"
        "# Build environment and exec real Pike\n"
        "_env=\"\"\n"
        "if [ -n \"$MOD_PATHS\" ]; then\n"
        "  _env=\"PIKE_MODULE_PATH=$MOD_PATHS${PIKE_MODULE_PATH+:$PIKE_MODULE_PATH}\"\n"
        "fi\n"
        "if [ -n \"$INC_PATHS\" ]; then\n"
        "  _env=\"${_env:+$_env }PIKE_INCLUDE_PATH=$INC_PATHS${PIKE_INCLUDE_PATH+:$PIKE_INCLUDE_PATH}\"\n"
        "fi\n"
        "\n"
        "if [ -n \"$_env\" ]; then\n"
        "  exec env $_env \"$PIKE_BIN\" \"$@\"\n"
        "else\n"
        "  exec \"$PIKE_BIN\" \"$@\"\n"
        "fi\n";

    Stdio.write_file(combine_path(env_bin, "pike"), wrapper);
    Process.run(({"chmod", "+x", combine_path(env_bin, "pike")}));

    // activate — idempotent, with proper deactivate (following uv patterns)
    string activate =
        "# pmp environment activation. Source this: . .pike-env/activate\n"
        "\n"
        "_pike_env_dir=\"" + abs_env_dir + "\"\n"
        "_pike_env_bin=\"$_pike_env_dir/bin\"\n"
        "\n"
        "# Idempotent: bail if already activated in this shell\n"
        "if [ -n \"${PIKE_ENV_PATH:-}\" ] && [ \"$PIKE_ENV_PATH\" = \"$_pike_env_dir\" ]; then\n"
        "  return 0\n"
        "fi\n"
        "\n"
        "pmp_deactivate() {\n"
        "  if [ -n \"${_pike_env_old_path:-}\" ]; then\n"
        "    PATH=\"$_pike_env_old_path\"\n"
        "    export PATH\n"
        "    unset _pike_env_old_path\n"
        "  fi\n"
        "  unset PIKE_ENV_PATH\n"
        "  if [ -n \"${_pike_env_old_ps1:-}\" ]; then\n"
        "    PS1=\"$_pike_env_old_ps1\"\n"
        "    export PS1\n"
        "    unset _pike_env_old_ps1\n"
        "  fi\n"
        "  hash -r 2>/dev/null || true\n"
        "  unset -f pmp_deactivate\n"
        "}\n"
        "\n"
        "# Save state\n"
        "_pike_env_old_path=\"$PATH\"\n"
        "_pike_env_old_ps1=\"${PS1:-}\"\n"
        "\n"
        "PATH=\"$_pike_env_bin:$PATH\"\n"
        "export PATH\n"
        "\n"
        "PIKE_ENV_PATH=\"$_pike_env_dir\"\n"
        "export PIKE_ENV_PATH\n"
        "\n"
        "PS1=\"(pike) ${PS1:-}\"\n"
        "export PS1\n"
        "\n"
        "hash -r 2>/dev/null || true\n";

    Stdio.write_file(combine_path(env_dir, "activate"), activate);

    info("created .pike-env/");
    info("  activate with:  . .pike-env/activate");
    info("  or use directly: .pike-env/bin/pike");
}

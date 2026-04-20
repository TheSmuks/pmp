#!/usr/bin/env pike
// pmp — Pike Module Package Manager
// Entry point — mutable state and command dispatch.
// Pure functions live in bin/Pmp.pmod/*.pmod

import Pmp;
import Arg;

// ── Configuration ──────────────────────────────────────────────────

string pike_bin;
string global_dir;
string local_dir = "./modules";
string store_dir;
string pike_json = "./pike.json";
string lockfile_path = "./pike.lock";

// ── Accumulated lockfile entries during install ─────────────────────

array(array(string)) lock_entries = ({});

// ── Cycle detection ────────────────────────────────────────────────

multiset(string) visited = (<>);

// ── Cached std_libs ────────────────────────────────────────────────

multiset(string) std_libs = (<>);

// ── Transitive dependency resolution ───────────────────────────────

//! Install a single dep from source, including transitive resolution.
void install_one(string name, string source, string target) {
    string type = detect_source_type(source);

    switch (type) {
        case "local": {
            string local_path = source;
            string project_root = find_project_root() || getcwd();
            if (has_prefix(local_path, "./"))
                local_path = combine_path(project_root, local_path);

            if (!Stdio.is_dir(local_path))
                die("local path not found: " + local_path);

            string dest = combine_path(target, name);
            Stdio.mkdirhier(target);
            // Remove existing symlink/dir if present
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(local_path, dest);
            info("linked " + name + " -> " + local_path);

            lock_entries = lockfile_add_entry(lock_entries,
                name, source, "-", "-", "-");
            break;
        }
        case "github":
        case "gitlab":
        case "selfhosted": {
            string ver = source_to_version(source);
            string repo_path = source_to_repo_path(source);
            string domain = source_to_domain(source);

            // Resolve version if not pinned
            if (ver == "") {
                array(string) resolved =
                    latest_tag(type, domain, repo_path, PMP_VERSION);
                if (sizeof(resolved[0]) == 0)
                    die("no tags found for " + repo_path);
                ver = resolved[0];
            }

            // Check for cycle
            string visit_key = type + ":" + repo_path + "#" + ver;
            if (visited[visit_key]) {
                info("skipping already-visited " + visit_key
                     + " (cycle or duplicate)");
                return;
            }
            visited[visit_key] = 1;

            // Check if already in modules/
            string dest = combine_path(target, name);
            if (Stdio.exist(dest)) {
                // Check version
                string version_file =
                    combine_path(dest, ".version");
                if (Stdio.exist(version_file)) {
                    string existing_ver =
                        Stdio.read_file(version_file);
                    if (existing_ver == ver) {
                        info("skipping " + name + " " + ver
                             + " (already installed)");
                        string sha = "";
                        switch (type) {
                            case "github":
                            case "gitlab":
                                sha = resolve_commit_sha(
                                    type, "", repo_path, ver, PMP_VERSION);
                                break;
                            case "selfhosted":
                                sha = resolve_commit_sha(
                                    type, domain, repo_path, ver, PMP_VERSION);
                                break;
                        }
                        sha = sha || "unknown";
                        lock_entries = lockfile_add_entry(lock_entries, name,
                            source_strip_version(source),
                            ver, sha, "unknown");
                        return;
                    } else {
                        warn(name + ": version " + ver
                             + " requested but " + existing_ver
                             + " already installed — keeping existing");
                        return;
                    }
                }
            }

            info("installing " + name + " (" + ver + ") from "
                 + type + ":" + repo_path);

            // Install to store
            mapping result;
            switch (type) {
                case "github":
                    result = store_install_github(store_dir,
                        repo_path, ver, PMP_VERSION);
                    break;
                case "gitlab":
                    result = store_install_gitlab(store_dir,
                        repo_path, ver, PMP_VERSION);
                    break;
                case "selfhosted":
                    result = store_install_selfhosted(store_dir,
                        domain, repo_path, ver, PMP_VERSION);
                    break;
            }

            // Symlink from modules/ to store entry
            Stdio.mkdirhier(target);
            string entry_full = combine_path(store_dir, result->entry);
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(entry_full, dest);

            // Write .version for compatibility with list command
            Stdio.write_file(combine_path(entry_full, ".version"), ver);

            info("installed " + name + " " + ver + " -> " + dest);
            lock_entries = lockfile_add_entry(lock_entries, name,
                source_strip_version(source),
                result->tag, result->sha, result->hash);

            // Resolve transitive dependencies
            string pkg_json = combine_path(entry_full, "pike.json");
            if (Stdio.exist(pkg_json)) {
                array(array(string)) trans_deps =
                    parse_deps(pkg_json);
                foreach (trans_deps; ; array(string) dep) {
                    info("  transitive: " + dep[0] + " from " + dep[1]);
                    install_one(dep[0], dep[1], target);
                }
            }
            break;
        }
    }
}

// ── Commands ───────────────────────────────────────────────────────

void cmd_version() {
    info("pmp v" + PMP_VERSION);
}

void cmd_init() {
    if (Stdio.exist(pike_json))
        die("pike.json already exists in this directory");

    string content = "{\n  \"dependencies\": {}\n}\n";
    Stdio.write_file(pike_json, content);
    info("created pike.json");
}

void cmd_install(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    int global_flag = opts->g || 0;
    string source = sizeof(rest) > 0 ? rest[0] : "";

    string target;
    if (global_flag)
        target = global_dir;
    else
        target = local_dir;

    if (source == "") {
        if (!Stdio.exist(pike_json))
            die("no pike.json found in current directory");
        cmd_install_all(target);
    } else {
        visited = (<>);
        lock_entries = ({});
        cmd_install_source(source, target);
        if (!global_flag) {
            write_lockfile(lockfile_path, lock_entries);
            if (Stdio.exist(pike_json)) {
                string name = source_to_name(source);
                string clean_source = source_strip_version(source);
                add_to_manifest(pike_json, name, clean_source);
            }
            validate_manifests(local_dir, std_libs);
        }
    }
}

void cmd_install_all(string target) {
    visited = (<>);
    lock_entries = ({});

    // Check if lockfile exists and covers all deps
    int use_lockfile = 0;
    if (Stdio.exist(lockfile_path) && target == local_dir) {
        use_lockfile = 1;
        int lockfile_complete = 1;

        array(array(string)) deps = parse_deps(pike_json);
        foreach (deps; ; array(string) dep) {
            if (!lockfile_has_dep(dep[0])) {
                lockfile_complete = 0;
                break;
            }
        }

        if (lockfile_complete) {
            info("installing from " + lockfile_path + " (up to date)");
            array(array(string)) lf_entries = read_lockfile(lockfile_path);
            foreach (lf_entries; ; array(string) entry) {
                string ln = entry[0], ls = entry[1],
                       lt = entry[2], lsha = entry[3],
                       lhash = entry[4];
                if (sizeof(ln) == 0) continue;

                if (ls == "-" || has_prefix(ls, "./")
                    || has_prefix(ls, "/")) {
                    // Local dep — just symlink
                    if (sizeof(ls) > 0 && ls != "-") {
                        string local_path = ls;
                        string project_root =
                            find_project_root() || getcwd();
                        if (has_prefix(local_path, "./"))
                            local_path =
                                combine_path(project_root, local_path);

                        if (!Stdio.is_dir(local_path)) {
                            warn("local dep " + ln + " path "
                                 + local_path + " not found");
                            continue;
                        }
                        Stdio.mkdirhier(target);
                        string dest = combine_path(target, ln);
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(local_path, dest);
                        info("linked " + ln + " -> " + local_path);
                    }
                } else {
                    // Remote dep — find store entry
                    string slug = replace(ls, "/", "-");
                    string pattern = slug + "-" + lt + "-*";
                    string found_entry = "";

                    if (Stdio.is_dir(store_dir)) {
                        foreach (get_dir(store_dir) || ({}); ;
                                 string se) {
                            if (glob(pattern, se) &&
                                Stdio.is_dir(
                                    combine_path(store_dir, se))) {
                                found_entry = se;
                                break;
                            }
                        }
                    }

                    if (sizeof(found_entry) > 0) {
                        Stdio.mkdirhier(target);
                        string dest = combine_path(target, ln);
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(
                            combine_path(store_dir, found_entry),
                            dest);
                        info("installed " + ln + " " + lt
                             + " (from lockfile)");
                    } else {
                        info("lockfile entry for " + ln
                             + " not in store — re-resolving");
                        use_lockfile = 0;
                    }
                }
                lock_entries = lockfile_add_entry(lock_entries,
                    ln, ls, lt, lsha, lhash);
            }
        } else {
            info("lockfile is stale — re-resolving missing deps");
            use_lockfile = 0;
        }
    }

    if (!use_lockfile) {
        info("installing dependencies from pike.json...");
        array(array(string)) deps = parse_deps(pike_json);
        foreach (deps; ; array(string) dep)
            install_one(dep[0], dep[1], target);
    }

    if (target == local_dir) {
        write_lockfile(lockfile_path, lock_entries);
        validate_manifests(local_dir, std_libs);
    }

    info("done");
}

void cmd_install_source(string source, string target) {
    string name = source_to_name(source);
    visited = (<>);
    install_one(name, source, target);
}

void cmd_update(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    string mod_name = sizeof(rest) > 0 ? rest[0] : "";

    // Remove lockfile to force fresh resolution
    if (Stdio.exist(lockfile_path)) rm(lockfile_path);

    if (sizeof(mod_name) > 0) {
        info("updating " + mod_name + "...");
        string src = "";
        array(array(string)) deps = parse_deps(pike_json);
        foreach (deps; ; array(string) dep) {
            if (dep[0] == mod_name) { src = dep[1]; break; }
        }
        if (sizeof(src) == 0)
            die("module " + mod_name + " not found in pike.json");
        visited = (<>);
        lock_entries = ({});
        install_one(mod_name, src, local_dir);
        write_lockfile(lockfile_path, lock_entries);
    } else {
        if (!Stdio.exist(pike_json))
            die("no pike.json found");
        cmd_install_all(local_dir);
    }
}

void cmd_lock() {
    if (!Stdio.exist(pike_json))
        die("no pike.json found");
    visited = (<>);
    lock_entries = ({});

    info("resolving dependencies...");
    array(array(string)) deps = parse_deps(pike_json);
    foreach (deps; ; array(string) dep)
        install_one(dep[0], dep[1], local_dir);

    write_lockfile(lockfile_path, lock_entries);
    info("lockfile written");
}

void cmd_store(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    string subcmd = sizeof(rest) > 0 ? rest[0] : "";

    switch (subcmd) {
        case "prune": {
            if (!Stdio.is_dir(store_dir)) {
                info("no store directory");
                return;
            }
            int pruned = 0;
            foreach (get_dir(store_dir) || ({}); ; string ename) {
                string entry = combine_path(store_dir, ename);
                if (!Stdio.is_dir(entry)) continue;

                if (Stdio.is_dir(local_dir)) {
                    int found = 0;
                    foreach (get_dir(local_dir) || ({}); ;
                             string lname) {
                        string link = combine_path(local_dir, lname);
                        mixed err = catch {
                            string target = System.readlink(link);
                            if (target && has_value(target, ename)) {
                                found = 1;
                                break;
                            }
                        };
                    }
                    if (!found) {
                        // Not linked from this project —
                        // but could be from others
                        info("unused store entry: " + ename);
                        pruned = 1;
                    }
                }
            }
            if (!pruned) info("no unused entries found");
            break;
        }
        case "": {
            // Show store status
            if (!Stdio.is_dir(store_dir)) {
                info("store is empty (" + store_dir + ")");
                return;
            }
            int count = 0;
            foreach (get_dir(store_dir) || ({}); ; string ename) {
                string entry = combine_path(store_dir, ename);
                if (!Stdio.is_dir(entry)) continue;

                string tag = "";
                string meta_file =
                    combine_path(entry, ".pmp-meta");
                if (Stdio.exist(meta_file)) {
                    string meta = Stdio.read_file(meta_file);
                    foreach (meta / "\n"; ; string line) {
                        if (has_prefix(line, "tag\t"))
                            tag = line[4..];
                    }
                }

                // Get size using du
                mapping r = Process.run(
                    ({"du", "-sh", entry}));
                string esize = "";
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    esize = (r->stdout / "\t")[0];

                write(sprintf("  %-55s %s\n", ename, esize));
                count++;
            }
            // Total size
            mapping r = Process.run(({"du", "-sh", store_dir}));
            string total = "";
            if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                total = (r->stdout / "\t")[0];
            write(sprintf("\n  %d entries, %s total\n", count, total));
            break;
        }
        default:
            die("unknown store subcommand: " + subcmd);
    }
}

void cmd_list(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    string dir = opts->g ? global_dir : local_dir;

    if (!Stdio.is_dir(dir)) {
        info("no modules installed");
        return;
    }

    int found = 0;
    foreach (get_dir(dir) || ({}); ; string mod_name) {
        string moddir = combine_path(dir, mod_name);
        if (!Stdio.is_dir(moddir)) continue;

        string ver = "(unknown)";
        string ver_file = combine_path(moddir, ".version");
        if (Stdio.exist(ver_file))
            ver = Stdio.read_file(ver_file) || "(unknown)";

        string src = "";
        mixed err = catch {
            string link = System.readlink(moddir);
            if (link && has_prefix(link, store_dir)) {
                src = " (store: " + (link / "/")[-1] + ")";
            } else if (link) {
                src = " -> " + link;
            }
        };

        write(sprintf("  %-20s %-12s%s\n", mod_name, ver, src));
        found = 1;
    }

    if (!found) info("no modules installed");
}

void cmd_clean() {
    if (Stdio.is_dir(local_dir)) {
        Stdio.recursive_rm(local_dir);
        info("removed " + local_dir + " (store preserved)");
    } else {
        info("nothing to clean");
    }
}

//! Build module + include paths from project root and global dir.
array(array(string)) build_paths() {
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

    if (Stdio.is_dir(global_dir)) {
        mod_paths += ({ global_dir });
        mapping r = Process.run(
            ({"find", global_dir, "-name", "*.h",
              "-print", "-quit"}));
        if (r->exitcode == 0 && sizeof(r->stdout) > 0)
            inc_paths += ({ global_dir });
    }

    return ({ mod_paths, inc_paths });
}

void cmd_remove(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    if (sizeof(rest) == 0)
        die("usage: pmp remove <name>");
    string name = rest[0];

    // Remove from pike.json
    if (Stdio.exist(pike_json)) {
        string raw = Stdio.read_file(pike_json);
        if (raw) {
            mixed data;
            mixed err = catch { data = Standards.JSON.decode(raw); };
            if (!err && mappingp(data) && mappingp(data->dependencies)) {
                if (!zero_type(data->dependencies[name])) {
                    m_delete(data->dependencies, name);
                    Stdio.write_file(pike_json,
                        Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");
                    info("removed " + name + " from pike.json");
                }
            }
        }
    }

    // Remove symlink
    string link = combine_path(local_dir, name);
    if (Stdio.exist(link)) {
        rm(link);
        info("removed " + link);
    }

    // Update lockfile
    if (Stdio.exist(lockfile_path)) {
        array(array(string)) entries = read_lockfile(lockfile_path);
        array(array(string)) new_entries = ({});
        foreach (entries; ; array(string) e)
            if (e[0] != name) new_entries += ({ e });
        lock_entries = new_entries;
        write_lockfile(lockfile_path, lock_entries);
    }
}

void cmd_run(array(string) args) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    if (sizeof(rest) == 0)
        die("usage: pmp run <script.pike> [args...]");

    string script = rest[0];
    array(string) script_args = rest[1..];

    array(array(string)) paths = build_paths();
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
        Process.exece(pike_bin,
            ({ pike_bin, script, @script_args }), env);
    } else {
        Process.exec(pike_bin, script, @script_args);
    }
}

// ── Environment ────────────────────────────────────────────────────

void cmd_env() {
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
        pike_bin, project_root, PMP_VERSION);
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

// ── Main ───────────────────────────────────────────────────────────

void print_help() {
    write("pmp — Pike Module Package Manager\n\n");
    write("Usage:\n");
    write("  pmp init                                    "
          "Create pike.json\n");
    write("  pmp install                                 "
          "Install all deps (from lockfile or pike.json)\n");
    write("  pmp install <url>                           "
          "Add and install dependency\n");
    write("  pmp install <url>#tag                       "
          "Install specific version\n");
    write("  pmp install ./local/path                    "
          "Local dependency (symlinked)\n");
    write("  pmp install -g <url>                        "
          "Install system-wide\n");
    write("  pmp update [module]                         "
          "Update deps to latest tags\n");
    write("  pmp lock                                    "
          "Write pike.lock\n");
    write("  pmp store                                   "
          "Show store entries and disk usage\n");
    write("  pmp store prune                             "
          "Show unused store entries\n");
    write("  pmp list [-g]                               "
          "Show installed dependencies\n");
    write("  pmp env                                     "
          "Create .pike-env/ virtual environment\n");
    write("  pmp clean                                   "
          "Remove ./modules/ (keeps store)\n");
    write("  pmp remove <name>                         "
          "Remove a dependency\n");
    write("  pmp run <script>                            "
          "Run script with module paths\n");
    write("  pmp version                                 "
          "Show version\n");
    write("\nSource formats:\n");
    write("  github.com/owner/repo                       "
          "GitHub\n");
    write("  gitlab.com/owner/repo                       "
          "GitLab\n");
    write("  git.example.com/owner/repo                  "
          "Self-hosted git\n");
    write("  ./local/path or /abs/path                   "
          "Local module\n");
}

int main(int argc, array(string) argv) {
    // Configuration
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    pike_bin = getenv("PIKE_BIN")
        || Process.locate_binary(search_path, "pike8.0")
        || Process.locate_binary(search_path, "pike")
        || "/usr/local/pike/8.0.1116/bin/pike";
    global_dir = combine_path(getenv("HOME") || "/tmp", ".pike/modules");
    store_dir = combine_path(getenv("HOME") || "/tmp", ".pike/store");

    mapping opts = Arg.parse(argv);
    array(string) rest = opts[Arg.REST];

    if (opts->help) { print_help(); return 0; }
    if (opts->version) { cmd_version(); return 0; }
    if (sizeof(rest) == 0) { print_help(); return 0; }

    string cmd = rest[0];
    array(string) args = rest[1..];

    switch (cmd) {
        case "init":     cmd_init(); break;
        case "install":  cmd_install(args); break;
        case "update":   cmd_update(args); break;
        case "lock":     cmd_lock(); break;
        case "store":    cmd_store(args); break;
        case "list":     cmd_list(args); break;
        case "clean":    cmd_clean(); break;
        case "remove":   cmd_remove(args); break;
        case "run":       cmd_run(args); break;
        case "env":      cmd_env(); break;
        case "version":  cmd_version(); break;
        default:
            die("unknown command '" + cmd + "' (try: pmp --help)");
    }
    return 0;
}
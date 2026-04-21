// Install.pmod — install orchestrators: install_one, cmd_install, cmd_update, cmd_lock
// All state is passed via context mapping (ctx).

inherit .Config;
inherit .Helpers;
inherit .Source;
inherit .Http;
inherit .Resolve;
inherit .Store;
inherit .Lockfile;
inherit .Manifest;
inherit .Validate;

//! Install a single dep from source, including transitive resolution.
void install_one(string name, string source, string target,
                 mapping ctx) {
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

            ctx["lock_entries"] = lockfile_add_entry(ctx["lock_entries"],
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
            if (ctx["visited"][visit_key]) {
                info("skipping already-visited " + visit_key
                     + " (cycle or duplicate)");
                return;
            }
            ctx["visited"][visit_key] = 1;

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
                        ctx["lock_entries"] = lockfile_add_entry(
                            ctx["lock_entries"], name,
                            source_strip_version(source),
                            ver, sha, "unknown");
                        return;
                    } else {
                        if (ctx["force"]) {
                            info(name + ": replacing " + existing_ver
                                 + " with " + ver + " (update)");
                            // Remove existing symlink — install will replace it
                            if (Stdio.exist(dest)) rm(dest);
                            // Fall through to fresh install below
                        } else {
                            warn(name + ": version " + ver
                                 + " requested but " + existing_ver
                                 + " already installed — keeping existing");
                            // Record the kept version in lockfile
                            string kept_sha = "";
                            switch (type) {
                                case "github":
                                case "gitlab":
                                    kept_sha = resolve_commit_sha(
                                        type, "", repo_path, existing_ver, PMP_VERSION);
                                    break;
                                case "selfhosted":
                                    kept_sha = resolve_commit_sha(
                                        type, domain, repo_path, existing_ver, PMP_VERSION);
                                    break;
                            }
                            kept_sha = kept_sha || "unknown";
                            ctx["lock_entries"] = lockfile_add_entry(
                                ctx["lock_entries"], name,
                                source_strip_version(source),
                                existing_ver, kept_sha, "unknown");
                            return;
                        }
                    }
                }
            }

            info("installing " + name + " (" + ver + ") from "
                 + type + ":" + repo_path);

            // Install to store
            mapping result;
            switch (type) {
                case "github":
                    result = store_install_github(ctx["store_dir"],
                        repo_path, ver, PMP_VERSION);
                    break;
                case "gitlab":
                    result = store_install_gitlab(ctx["store_dir"],
                        repo_path, ver, PMP_VERSION);
                    break;
                case "selfhosted":
                    result = store_install_selfhosted(ctx["store_dir"],
                        domain, repo_path, ver, PMP_VERSION);
                    break;
                default:
                    die("unsupported source type: " + type);
            }

            // Symlink from modules/ to store entry
            Stdio.mkdirhier(target);
            string entry_full = combine_path(ctx["store_dir"], result->entry);
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(entry_full, dest);

            // Write .version for compatibility with list command
            Stdio.write_file(combine_path(entry_full, ".version"), ver);

            info("installed " + name + " " + ver + " -> " + dest);
            ctx["lock_entries"] = lockfile_add_entry(ctx["lock_entries"], name,
                source_strip_version(source),
                result->tag, result->sha, result->hash);

            // Resolve transitive dependencies
            string pkg_json = combine_path(entry_full, "pike.json");
            if (Stdio.exist(pkg_json)) {
                array(array(string)) trans_deps =
                    parse_deps(pkg_json);
                foreach (trans_deps; ; array(string) dep) {
                    info("  transitive: " + dep[0] + " from " + dep[1]);
                    install_one(dep[0], dep[1], target, ctx);
                }
            }
            break;
        }
        default:
            die("unsupported source type: " + type);
    }
}

void cmd_install_all(string target, mapping ctx) {
    ctx["visited"] = (<>);
    ctx["lock_entries"] = ({});

    // Check if lockfile exists and covers all deps
    int use_lockfile = 0;
    if (Stdio.exist(ctx["lockfile_path"]) && target == ctx["local_dir"]) {
        use_lockfile = 1;
        int lockfile_complete = 1;

        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        foreach (deps; ; array(string) dep) {
            if (!lockfile_has_dep(dep[0], ctx["lockfile_path"], dep[1])) {
                lockfile_complete = 0;
                break;
            }
        }

        if (lockfile_complete) {
            info("installing from " + ctx["lockfile_path"] + " (up to date)");
            array(array(string)) lf_entries = read_lockfile(ctx["lockfile_path"]);
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

                    if (Stdio.is_dir(ctx["store_dir"])) {
                        foreach (get_dir(ctx["store_dir"]) || ({}); ;
                                 string se) {
                            if (glob(pattern, se) &&
                                Stdio.is_dir(
                                    combine_path(ctx["store_dir"], se))) {
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
                            combine_path(ctx["store_dir"], found_entry),
                            dest);
                        info("installed " + ln + " " + lt
                             + " (from lockfile)");
                    } else {
                        info("lockfile entry for " + ln
                             + " not in store — re-resolving");
                        use_lockfile = 0;
                        break;
                    }
                }
                // Only add lockfile entry if we're still using lockfile
                if (use_lockfile)
                    ctx["lock_entries"] = lockfile_add_entry(ctx["lock_entries"],
                        ln, ls, lt, lsha, lhash);
            }
        } else {
            info("lockfile is stale — re-resolving missing deps");
            use_lockfile = 0;
        }
    }

    if (!use_lockfile) {
        ctx["lock_entries"] = ({});
        info("installing dependencies from pike.json...");
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        foreach (deps; ; array(string) dep)
            install_one(dep[0], dep[1], target, ctx);
    }

    if (target == ctx["local_dir"]) {
        // Prune entries for deps no longer in pike.json
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        multiset(string) dep_names = (<>);
        foreach (deps; ; array(string) d)
            dep_names[d[0]] = 1;
        array(array(string)) filtered = ({});
        foreach (ctx["lock_entries"]; ; array(string) e)
            if (dep_names[e[0]]) filtered += ({ e });
        ctx["lock_entries"] = filtered;
        write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
        validate_manifests(ctx["local_dir"], ctx["std_libs"]);
    }

    info("done");
}

void cmd_install_source(string source, string target, mapping ctx) {
    string name = source_to_name(source);
    ctx["visited"] = (<>);
    install_one(name, source, target, ctx);
}

void cmd_install(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    int global_flag = opts->g || 0;
    string source = sizeof(rest) > 0 ? rest[0] : "";

    string target;
    if (global_flag)
        target = ctx["global_dir"];
    else
        target = ctx["local_dir"];

    if (source == "") {
        if (!Stdio.exist(ctx["pike_json"]))
            die("no pike.json found in current directory");
        cmd_install_all(target, ctx);
    } else {
        // Read existing lockfile entries to preserve them
        array(array(string)) existing = read_lockfile(ctx["lockfile_path"]);

        ctx["visited"] = (<>);
        ctx["lock_entries"] = ({});
        cmd_install_source(source, target, ctx);

        // Merge new entries into existing (dedup by name)
        ctx["lock_entries"] = merge_lock_entries(existing, ctx["lock_entries"]);

        if (!global_flag) {
            write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
            if (Stdio.exist(ctx["pike_json"])) {
                string name = source_to_name(source);
                string clean_source = source_strip_version(source);
                add_to_manifest(ctx["pike_json"], name, clean_source);
            }
            validate_manifests(ctx["local_dir"], ctx["std_libs"]);
        }
    }
}

void cmd_update(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    string mod_name = sizeof(rest) > 0 ? rest[0] : "";

    if (sizeof(mod_name) > 0) {
        info("updating " + mod_name + "...");
        string src = "";
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        foreach (deps; ; array(string) dep) {
            if (dep[0] == mod_name) { src = dep[1]; break; }
        }
        if (sizeof(src) == 0)
            die("module " + mod_name + " not found in pike.json");

        // Read existing lockfile entries (preserve other modules)
        array(array(string)) existing = read_lockfile(ctx["lockfile_path"]);

        ctx["visited"] = (<>);
        ctx["lock_entries"] = ({});
        ctx["force"] = 1;
        install_one(mod_name, src, ctx["local_dir"], ctx);
        m_delete(ctx, "force");

        // Merge: dedup by name — new entries replace existing
        ctx["lock_entries"] = merge_lock_entries(existing, ctx["lock_entries"]);
        write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
    } else {
        if (!Stdio.exist(ctx["pike_json"]))
            die("no pike.json found");
        ctx["force"] = 1;
        cmd_install_all(ctx["local_dir"], ctx);
        m_delete(ctx, "force");
    }
}

void cmd_lock(mapping ctx) {
    if (!Stdio.exist(ctx["pike_json"]))
        die("no pike.json found");
    ctx["visited"] = (<>);
    ctx["lock_entries"] = ({});

    info("resolving dependencies...");
    array(array(string)) deps = parse_deps(ctx["pike_json"]);
    foreach (deps; ; array(string) dep)
        install_one(dep[0], dep[1], ctx["local_dir"], ctx);

    write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
    info("lockfile written");
}

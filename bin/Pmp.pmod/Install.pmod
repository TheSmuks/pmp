// Install.pmod — install orchestrators: install_one, cmd_install, cmd_update, cmd_lock,
//                cmd_rollback, cmd_changelog
// All state is passed via context mapping (ctx).

inherit .Config;
inherit .Helpers;
inherit .Source;
inherit .Http;
inherit .Resolve;
inherit .Store;
inherit .Lockfile;
inherit .Manifest;
inherit .Semver;
inherit .Validate;


private string get_resolved_sha(string type, string domain,
                                 string repo_path, string ver,
                                 mapping ctx) {
    if (ctx["offline"]) return "-";
    switch (type) {
        case "github":
        case "gitlab":
            return resolve_commit_sha(type, "", repo_path, ver, PMP_VERSION) || "";
        case "selfhosted":
            return resolve_commit_sha(type, domain, repo_path, ver, PMP_VERSION) || "";
        default:
            return "";
    }
}

// ── Project-level lock ───────────────────────────────────────────────

private string _project_lock_path(string project_root) {
    return combine_path(project_root || getcwd(), ".pmp-install.lock");
}

//! Acquire a project-level advisory lock. Removes stale locks held by dead processes.
void project_lock(void|string project_root) {
    string lock_path = _project_lock_path(project_root);
    advisory_lock(lock_path, "project");
    register_project_lock_path(lock_path);
}

//! Release the project-level lock.
void project_unlock(void|string project_root) {
    string lock_path = _project_lock_path(project_root);
    advisory_unlock(lock_path);
    register_project_lock_path("");
}


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
            // Prevent path traversal in local dep resolution
            if (search(local_path, "..") >= 0) {
                warn("local dep path contains '..' traversal: " + source + " — skipping");
                break;
            }

            if (!Stdio.is_dir(local_path))
                die("local path not found: " + local_path);

            mapping rmp = resolve_module_path(name, local_path);
            string dest = combine_path(target, rmp->link_name);
            Stdio.mkdirhier(target);
            atomic_symlink(rmp->target, dest);
            info("linked " + name + " -> " + rmp->target);

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
                if (ctx["offline"])
                    die("offline mode: cannot resolve latest tag for "
                        + repo_path + " — pin a version in pike.json");
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

            // Check if already in modules/ (try both bare name and .pmod)
            string dest = combine_path(target, name);
            if (!Stdio.exist(dest)) {
                string alt = combine_path(target, name + ".pmod");
                if (Stdio.exist(alt)) dest = alt;
            }
            if (Stdio.exist(dest)) {
                // Check version — resolve through symlink to store entry root
                string resolved = get_symlink_target(dest) || dest;
                string version_dir = resolved;
                if (has_suffix(dest, ".pmod") && Stdio.exist(combine_path(resolved, ".."))) {
                    // .pmod symlink points inside store entry; .version is at entry root
                    if (!Stdio.is_file(combine_path(version_dir, ".version")))
                        version_dir = combine_path(resolved, "..");
                }
                string version_file =
                    combine_path(version_dir, ".version");
                if (Stdio.exist(version_file)) {
                    string existing_ver =
                        String.trim_all_whites(Stdio.read_file(version_file) || "");
                    if (existing_ver == ver) {
                        info("skipping " + name + " " + ver
                             + " (already installed)");
                        string sha = get_resolved_sha(type, domain,
                            repo_path, ver, ctx);
                        string content_hash = "";
                        if (Stdio.exist(combine_path(version_dir, ".pmp-meta")))
                            content_hash = read_stored_hash(version_dir) || "";
                        ctx["lock_entries"] = lockfile_add_entry(
                            ctx["lock_entries"], name,
                            source_strip_version(source),
                            ver, sha, content_hash);
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
                            string kept_sha = get_resolved_sha(type, domain,
                                repo_path, existing_ver, ctx);
                            string content_hash = "";
                            if (Stdio.exist(combine_path(version_dir, ".pmp-meta")))
                                content_hash = read_stored_hash(version_dir) || "";
                            ctx["lock_entries"] = lockfile_add_entry(
                                ctx["lock_entries"], name,
                                source_strip_version(source),
                                existing_ver, kept_sha, content_hash);
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
                    die("unsupported source type: " + type, EXIT_INTERNAL);
            }

            // Symlink from modules/ to store entry
            Stdio.mkdirhier(target);
            string entry_full = combine_path(ctx["store_dir"], result->entry);
            // Resolve module name from the package's pike.json if available
            string resolved_name = json_field("name", combine_path(entry_full, "pike.json"));
            // json_field returns raw JSON value — only accept strings
            if (!stringp(resolved_name)) resolved_name = name;
            // Sanitize package name from pike.json — prevent path traversal
            if (search(resolved_name, "/") >= 0 || search(resolved_name, "\\") >= 0
                || search(resolved_name, "..") >= 0 || search(resolved_name, "\0") >= 0
                || sizeof(resolved_name) == 0) {
                warn("package has invalid name '" + resolved_name + "' in pike.json — using dependency key");
                resolved_name = name;
            }
            // If resolved name differs from dependency key, clean up any
            // orphaned symlink under the dependency key from a previous install
            if (resolved_name != name) {
                string old_link = combine_path(target, name);
                string old_link_pmod = combine_path(target, name + ".pmod");
                if (Stdio.exist(old_link)) rm(old_link);
                if (Stdio.exist(old_link_pmod)) rm(old_link_pmod);
            }
            mapping rmp = resolve_module_path(resolved_name, entry_full);
            dest = combine_path(target, rmp->link_name);
            atomic_symlink(rmp->target, dest);

            // Write .version for compatibility with list command
            atomic_write(combine_path(entry_full, ".version"), ver);

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
            die("unsupported source type: " + type, EXIT_INTERNAL);
    }
}

void cmd_install_all(string target, mapping ctx) {
    ctx["visited"] = (<>);
    ctx["lock_entries"] = ({});

    // Snapshot existing symlinks BEFORE any changes so rollback can restore
    mapping(string:string) old_symlinks = ([]);
    if (Stdio.is_dir(target)) {
        foreach (get_dir(target) || ({}); ; string name) {
            string full = combine_path(target, name);
            string link = get_symlink_target(full);
            if (link) old_symlinks[name] = link;
        }
    }


    int install_ok = 0;
    int store_locked = 0;

    // Project-level lock: prevents concurrent installs in the same directory
    project_lock(find_project_root());
    store_lock(ctx["store_dir"]);
    store_locked = 1;

    // Check if lockfile exists and covers all deps
    int use_lockfile = 0;
    if (Stdio.exist(ctx["lockfile_path"]) && target == ctx["local_dir"]) {
        use_lockfile = 1;
        int lockfile_complete = 1;

        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        array(array(string)) lf_entries = read_lockfile(ctx["lockfile_path"]);
        foreach (deps; ; array(string) dep) {
            if (!lockfile_has_dep(dep[0], ctx["lockfile_path"], source_strip_version(dep[1]), lf_entries)) {
                lockfile_complete = 0;
                break;
            }
        }

        if (lockfile_complete) {
            info("installing from " + ctx["lockfile_path"] + " (up to date)");
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
                        mapping rmp = resolve_module_path(ln, local_path);
                        string dest = combine_path(target, rmp->link_name);
                        atomic_symlink(rmp->target, dest);
                        info("linked " + ln + " -> " + rmp->target);
                    }
                } else {
                // Remote dep — find store entry
                    string found_entry = _find_store_entry(
                        ctx["store_dir"], ls, lt, lhash);

                    if (sizeof(found_entry) > 0) {
                        string entry_full = combine_path(ctx["store_dir"], found_entry);

                        // Verify content integrity
                        if (sizeof(lhash) > 0) {
                            string stored = read_stored_hash(entry_full);
                            if (stored && stored != lhash) {
                                die("integrity mismatch for " + ln + ": "
                                    + "lockfile hash " + lhash
                                    + " != stored hash " + (stored || "none"), EXIT_INTERNAL);
                            } else if (!stored) {
                                warn("no stored hash for " + ln + " — skipping verification");
                            }
                        }

                        Stdio.mkdirhier(target);
                        mapping rmp = resolve_module_path(ln, entry_full);
                        string dest = combine_path(target, rmp->link_name);
                        atomic_symlink(rmp->target, dest);
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
            install_ok = 1;
        } else {
            if (ctx["frozen_lockfile"])
                die("frozen lockfile: lockfile does not cover all dependencies — "
                    + "run 'pmp install' without --frozen-lockfile first");
            info("lockfile is stale — re-resolving missing deps");
            use_lockfile = 0;
        }
    }

    if (!use_lockfile) {
        if (ctx["frozen_lockfile"])
                die("frozen lockfile: " + (Stdio.exist(ctx["lockfile_path"]) ?
                    "store entries missing — cannot satisfy lockfile" : "no lockfile found")
                    + " — run 'pmp install' without --frozen-lockfile first");
        if (ctx["offline"])
                die("offline mode: " + (Stdio.exist(ctx["lockfile_path"]) ?
                    "store entries missing — cannot satisfy lockfile" : "no lockfile found")
                    + " — cannot resolve without network");

        // Clean up any symlinks created during lockfile replay
        if (Stdio.is_dir(target)) {
            foreach (get_dir(target) || ({}); ; string name) {
                string full = combine_path(target, name);
                if (is_symlink(full)) rm(full);
            }
        }

        ctx["lock_entries"] = ({});

        // Atomic install: stage new symlinks, then swap atomically on
        // success or rollback on failure.
        string staging = target + ".tmp";
        // Clean up any leftover staging dir from a previous failed run
        if (Stdio.is_dir(staging)) Stdio.recursive_rm(staging);
        info("installing dependencies from pike.json...");
        mixed install_err = catch {
            array(array(string)) deps = parse_deps(ctx["pike_json"]);
            // Install to staging dir to avoid corrupting ./modules/
            foreach (deps; ; array(string) dep)
                install_one(dep[0], dep[1], staging, ctx);
        };

        if (install_err) {
            // Rollback: restore old symlinks
            if (Stdio.is_dir(staging)) Stdio.recursive_rm(staging);
            if (sizeof(old_symlinks) > 0) {
                Stdio.mkdirhier(target);
                foreach (old_symlinks; string name; string link) {
                    string dest = combine_path(target, name);
                    if (!Stdio.exist(dest))
                        symlink(link, dest);
                }
            }
            if (store_locked) store_unlock(ctx["store_dir"]);
            project_unlock(find_project_root());
            throw(install_err);
        }

        // Success: swap staging -> target atomically
        if (Stdio.is_dir(target)) {
            string backup = target + ".old";
            if (Stdio.is_dir(backup)) Stdio.recursive_rm(backup);
            if (!mv(target, backup)) {
                Stdio.recursive_rm(staging);
                die("failed to swap modules directory — install aborted");
            } else {
                if (!mv(staging, target)) {
                    // Cross-filesystem: copy contents then remove source
                    mixed cp_err = catch {
                        Stdio.mkdirhier(target);
                        foreach (get_dir(staging) || ({}); ; string name)
                            mv(combine_path(staging, name),
                               combine_path(target, name));
                        Stdio.recursive_rm(staging);
                    };
                    if (cp_err) {
                        // Total failure — try to restore backup
                        if (Stdio.is_dir(backup)) {
                            Stdio.recursive_rm(target);
                            mv(backup, target);
                        }
                        die("failed to swap modules directory");
                    }
                }
                // Safe cleanup: if backup is a symlink (old modules/ was a symlink),
                // just remove the symlink itself — don't follow it and destroy the target
                if (is_symlink(backup)) {
                    rm(backup);
                } else {
                    Stdio.recursive_rm(backup);
                }
                install_ok = 1;
            }
        } else {
            // No existing modules/ — just rename
            if (!mv(staging, target)) {
                // Cross-filesystem: copy contents then remove source
                mixed cp_err = catch {
                    Stdio.mkdirhier(target);
                    foreach (get_dir(staging) || ({}); ; string name)
                        mv(combine_path(staging, name),
                           combine_path(target, name));
                    Stdio.recursive_rm(staging);
                };
                if (cp_err) {
                    die("failed to move staging dir to modules");
                } else {
                    install_ok = 1;
                }
            } else {
                install_ok = 1;
            }
        }
    }

    if (target == ctx["local_dir"] && install_ok) {
        // Prune stale lockfile entries (deps removed from pike.json)
        // while preserving transitive deps of remaining direct deps.
        // Fresh installs already build lock_entries from scratch;
        // this targets the lockfile-replay path where old entries persist.
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        multiset(string) needed = (<>);
        array(string) queue = ({});
        foreach (deps; ; array(string) d) {
            needed[d[0]] = 1;
            queue += ({ d[0] });
        }

        // Build name -> lock_entry lookup for walking transitives
        mapping(string:array(string)) entry_by_name = ([]);
        foreach (ctx["lock_entries"]; ; array(string) e)
            if (sizeof(e[0]) > 0) entry_by_name[e[0]] = e;

        // BFS: walk transitive deps from each installed package's pike.json
        multiset(string) seen = (<>);
        while (sizeof(queue) > 0) {
            string n = queue[0];
            queue = queue[1..];
            if (seen[n]) continue;
            seen[n] = 1;
            array(string) e = entry_by_name[n];
            if (!e) continue;

            string pkg_json;
            if (e[1] == "-" || has_prefix(e[1], "./") || has_prefix(e[1], "/")) {
                // Local dep — read pike.json from source path
                string local_path = e[1];
                string project_root = find_project_root() || getcwd();
                if (has_prefix(local_path, "./"))
                    local_path = combine_path(project_root, local_path);
                pkg_json = combine_path(local_path, "pike.json");
            } else {
                // Remote dep — find in store
                string entry_path =
                    _find_store_entry(ctx["store_dir"], e[1], e[2], e[4]);
                if (!entry_path || sizeof(entry_path) == 0) continue;
                pkg_json = combine_path(ctx["store_dir"], entry_path, "pike.json");
            }
            if (!Stdio.exist(pkg_json)) continue;
            foreach (parse_deps(pkg_json); ; array(string) td) {
                if (!needed[td[0]]) {
                    needed[td[0]] = 1;
                    queue += ({ td[0] });
                }
            }
        }

        // Keep only reachable entries
        array(array(string)) filtered = ({});
        foreach (ctx["lock_entries"]; ; array(string) e)
            if (needed[e[0]]) filtered += ({ e });
        ctx["lock_entries"] = filtered;

        write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
        validate_manifests(ctx["local_dir"], ctx["std_libs"]);
    }

    if (store_locked)
        store_unlock(ctx["store_dir"]);
    project_unlock(find_project_root());
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
    int global_flag = opts->g || search(rest, "-g") >= 0 || 0;
    // Arg.parse only recognizes flags before the subcommand;
    // also check rest[] for flags placed after the command.
    rest -= ({"-g"});
    if (opts["frozen-lockfile"] || search(rest, "--frozen-lockfile") >= 0)
        ctx["frozen_lockfile"] = 1;
    rest -= ({"--frozen-lockfile"});
    if (opts->offline || search(rest, "--offline") >= 0)
        ctx["offline"] = 1;
    rest -= ({"--offline"});
    string source = sizeof(rest) > 0 ? rest[0] : "";

    // Flags for CI use
    if (opts["frozen-lockfile"]) ctx["frozen_lockfile"] = 1;
    if (opts->offline) ctx["offline"] = 1;

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

        project_lock(find_project_root());
        int store_locked = 0;
        mixed err = catch {
            store_lock(ctx["store_dir"]);
            store_locked = 1;
            ctx["visited"] = (<>);
            ctx["lock_entries"] = ({});

            // Snapshot existing symlinks so we can roll back new ones
            // if lockfile/manifest writes fail
            mapping(string:string) old_symlinks = ([]);
            if (Stdio.is_dir(target)) {
                foreach (get_dir(target) || ({}); ; string n) {
                    string full = combine_path(target, n);
                    string link = get_symlink_target(full);
                    if (link) old_symlinks[n] = link;
                }
            }

            cmd_install_source(source, target, ctx);

            // Merge new entries into existing (dedup by name)
            ctx["lock_entries"] = merge_lock_entries(existing, ctx["lock_entries"]);

            // Post-install bookkeeping — if this fails, remove new symlinks
            // to keep project state consistent
            string old_lockfile = Stdio.exist(ctx["lockfile_path"]) ? Stdio.read_file(ctx["lockfile_path"]) : 0;
            string old_pike_json = Stdio.exist(ctx["pike_json"]) ? Stdio.read_file(ctx["pike_json"]) : 0;

            mixed post_err = catch {
                if (!global_flag) {
                    write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
                    if (Stdio.exist(ctx["pike_json"])) {
                        string name = source_to_name(source);
                        string clean_source = source_strip_version(source);
                        add_to_manifest(ctx["pike_json"], name, clean_source);
                    }
                    validate_manifests(ctx["local_dir"], ctx["std_libs"]);
                }
            };
            if (post_err) {
                // Remove symlinks created by this install
                if (Stdio.is_dir(target)) {
                    foreach (get_dir(target) || ({}); ; string n) {
                        if (!old_symlinks[n]) {
                            string full = combine_path(target, n);
                            if (is_symlink(full)) rm(full);
                        }
                    }
                }
                catch {
                    if (old_lockfile != 0)
                        atomic_write(ctx["lockfile_path"], old_lockfile);
                    else if (Stdio.exist(ctx["lockfile_path"]))
                        rm(ctx["lockfile_path"]);
                };
                if (old_pike_json != 0)
                    catch { atomic_write(ctx["pike_json"], old_pike_json); };
                throw(post_err);
            }
        };
        if (store_locked) store_unlock(ctx["store_dir"]);
        project_unlock(find_project_root());
        if (err) throw(err);
    }
}

//! Print update summary table comparing old and new lockfile entries.
void print_update_summary(array(array(string)) old_entries,
                           array(array(string)) new_entries) {
    // Build lookup from name -> entry
    mapping(string:array(string)) old_map = ([]);
    foreach (old_entries; ; array(string) e)
        old_map[e[0]] = e;

    int any_change = 0;
    String.Buffer buf = String.Buffer();
    foreach (new_entries; ; array(string) e) {
        string name = e[0];
        string new_tag = e[2];
        if (old_map[name]) {
            string old_tag = old_map[name][2];
            if (old_tag != new_tag && old_tag != "-" && new_tag != "-") {
                string bump = classify_bump(old_tag, new_tag);
                string label = bump == "major" ? "MAJOR" : bump;
                buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                    name, old_tag, new_tag, label));
                any_change = 1;
            }
        }
    }

    if (any_change) {
        info("update summary:");
        write(sprintf("  %-20s %-12s %-12s %s\n",
            "MODULE", "OLD", "NEW", "CHANGE"));
        write(buf->get());
    }
}

void cmd_update(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    string mod_name = sizeof(rest) > 0 ? rest[0] : "";

    // Save old lockfile entries for summary comparison
    array(array(string)) old_entries = read_lockfile(ctx["lockfile_path"]);

    mixed err = catch {
        if (sizeof(mod_name) > 0) {
            // Single-module path: acquire project + store locks here
            // (update-all path delegates to cmd_install_all which handles its own locking)
            project_lock(find_project_root());
            store_lock(ctx["store_dir"]);
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

            // Snapshot existing symlink so we can restore on download failure
            string saved_symlink = 0;
            string saved_dest = combine_path(ctx["local_dir"], mod_name);
            if (Stdio.exist(saved_dest)) {
                saved_symlink = get_symlink_target(saved_dest);
            } else {
                string alt = combine_path(ctx["local_dir"], mod_name + ".pmod");
                if (Stdio.exist(alt)) {
                    saved_dest = alt;
                    saved_symlink = get_symlink_target(alt);
                }
            }

            ctx["visited"] = (<>);
            ctx["lock_entries"] = ({});
            ctx["force"] = 1;
            mixed single_err = catch {
                install_one(mod_name, src, ctx["local_dir"], ctx);
            };
            if (single_err) {
                // Restore symlink removed by force-install on download failure
                if (saved_symlink) {
                    if (!Stdio.exist(saved_dest)) {
                        atomic_symlink(saved_symlink, saved_dest);
                    }
                }
                throw(single_err);
            }
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
    };
    if (sizeof(mod_name) > 0) {
        // Ensure locks released on error in single-module path
        store_unlock(ctx["store_dir"]);
        project_unlock(find_project_root());
    }
    if (err) throw(err);

    // Print update summary
    array(array(string)) new_entries = read_lockfile(ctx["lockfile_path"]);
    print_update_summary(old_entries, new_entries);
}

void cmd_lock(mapping ctx) {
    if (!Stdio.exist(ctx["pike_json"]))
        die("no pike.json found");

    project_lock(find_project_root());
    int store_locked = 0;
    mixed err = catch {
        store_lock(ctx["store_dir"]);
        store_locked = 1;

        ctx["visited"] = (<>);
        ctx["lock_entries"] = ({});

        info("resolving dependencies...");
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        foreach (deps; ; array(string) dep)
            install_one(dep[0], dep[1], ctx["local_dir"], ctx);

        write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
        info("lockfile written");
    };
    if (store_locked) store_unlock(ctx["store_dir"]);
    project_unlock(find_project_root());
    if (err) throw(err);
}

//! Rollback all modules to the previous lockfile state.
//! Reads pike.lock.prev and re-symlinks modules to those versions.
void cmd_rollback(mapping ctx) {
    string prev_path = ctx["lockfile_path"] + ".prev";
    if (!Stdio.exist(prev_path))
        die("no previous lockfile found (" + prev_path + ")");

    array(array(string)) prev_entries = read_lockfile(prev_path);
    if (sizeof(prev_entries) == 0)
        die("previous lockfile is empty");

    project_lock(find_project_root());
    store_lock(ctx["store_dir"]);
    mixed err = catch {
        string target = ctx["local_dir"];
        Stdio.mkdirhier(target);

        // Remove modules not in previous lockfile
        multiset(string) prev_names = (<>);
        foreach (prev_entries; ; array(string) entry)
            if (sizeof(entry[0]) > 0) prev_names[entry[0]] = 1;

        if (Stdio.is_dir(target)) {
            foreach (get_dir(target) || ({}); ; string name) {
                string full = combine_path(target, name);
                string link = get_symlink_target(full);
                // Strip .pmod suffix for comparison with lockfile names
                string bare = has_suffix(name, ".pmod") ? name[..<5] : name;
                if (link && !prev_names[bare] && !prev_names[name]) {
                    rm(full);
                    info("removed " + name + " (not in previous lockfile)");
                }
            }
        }

        // Track which entries are actually restored so the lockfile
        // reflects reality if some entries are skipped.
        array(array(string)) restored_entries = ({});

        foreach (prev_entries; ; array(string) entry) {
            string ln = entry[0], ls = entry[1],
                   lt = entry[2], lsha = entry[3],
                   lhash = entry[4];
            if (sizeof(ln) == 0) continue;

            string dest = combine_path(target, ln);

            if (ls == "-" || has_prefix(ls, "./") || has_prefix(ls, "/")) {
                // Local dep — re-symlink
                if (sizeof(ls) > 0 && ls != "-") {
                    string local_path = ls;
                    string project_root = find_project_root() || getcwd();
                    if (has_prefix(local_path, "./"))
                        local_path = combine_path(project_root, local_path);
                    if (!Stdio.is_dir(local_path)) {
                        warn("local dep " + ln + " path " + local_path
                             + " not found — skipping");
                        continue;
                    }
                    mapping rmp = resolve_module_path(ln, local_path);
                    string dest_rm = combine_path(target, rmp->link_name);
                    // Remove complementary symlink variant
                    if (dest != dest_rm) {
                        rm(dest);
                        if (!has_suffix(dest_rm, ".pmod")) {
                            string pmod_alt = dest_rm + ".pmod";
                            if (Stdio.exist(pmod_alt)) rm(pmod_alt);
                        }
                    }
                    atomic_symlink(rmp->target, dest_rm);
                    info("restored " + ln + " -> " + rmp->target);
                    restored_entries += ({ entry });
                }
            } else {
                // Remote dep — find store entry matching source+tag
                string found_entry = _find_store_entry(
                    ctx["store_dir"], ls, lt, lhash);

                if (sizeof(found_entry) == 0) {
                    warn("store entry not found for " + ln + " " + lt
                         + " — skipping (store entry may have been pruned)");
                    continue;
                }

                string entry_full = combine_path(ctx["store_dir"], found_entry);
                mapping rmp = resolve_module_path(ln, entry_full);
                string dest_rm = combine_path(target, rmp->link_name);
                // Remove complementary symlink variant (bare vs .pmod)
                if (dest != dest_rm) {
                    if (Stdio.exist(dest)) rm(dest);
                    // Also remove .pmod variant if resolved name is bare
                    if (!has_suffix(dest_rm, ".pmod")) {
                        string pmod_alt = dest_rm + ".pmod";
                        if (Stdio.exist(pmod_alt)) rm(pmod_alt);
                    }
                }
                atomic_symlink(rmp->target, dest_rm);
                info("restored " + ln + " " + lt);
                restored_entries += ({ entry });
            }

        }

        write_lockfile(ctx["lockfile_path"], restored_entries);

        info("rollback complete — restored " + sizeof(restored_entries) + " modules");
    };
    store_unlock(ctx["store_dir"]);
    project_unlock(find_project_root());
    if (err) throw(err);
}

//! Show changes between versions for a specific module.
//! Compares current lockfile with .prev lockfile.
void cmd_changelog(array(string) args, mapping ctx) {
    if (sizeof(args) == 0)
        die("usage: pmp changelog <module>");

    string mod_name = args[0];
    string prev_path = ctx["lockfile_path"] + ".prev";

    array(array(string)) current = read_lockfile(ctx["lockfile_path"]);
    array(array(string)) prev = read_lockfile(prev_path);

    // Find module in both lockfiles
    array(string) cur_entry = 0;
    array(string) prev_entry = 0;
    foreach (current; ; array(string) e)
        if (e[0] == mod_name) { cur_entry = e; break; }
    foreach (prev; ; array(string) e)
        if (e[0] == mod_name) { prev_entry = e; break; }

    if (!cur_entry)
        die("module " + mod_name + " not found in current lockfile");
    if (!prev_entry)
        die("module " + mod_name + " not found in previous lockfile"
            + " — no version to compare against");

    string cur_tag = cur_entry[2];
    string prev_tag = prev_entry[2];
    string cur_sha = cur_entry[3];
    string prev_sha = prev_entry[3];

    if (cur_sha == prev_sha) {
        if (cur_sha == "-") {
            info(mod_name + ": local dependency — no remote changelog available");
            return;
        }
        info(mod_name + ": no changes (" + cur_tag + " == " + prev_tag + ")");
        return;
    }

    write("pmp: " + mod_name + " " + prev_tag + " -> " + cur_tag + "\n");

    // Detect source type from the source field
    string source = cur_entry[1];
    string type = detect_source_type(source);

    if (type == "local") {
        write("pmp: local dependency — no remote changelog available\n");
        return;
    }

    string repo_path = source_to_repo_path(source);
    string domain = source_to_domain(source);

    // Fetch commit log between versions
    switch (type) {
        case "github": {
            // GitHub compare API
            string url = "https://api.github.com/repos/" + repo_path
                         + "/compare/" + prev_sha + "..." + cur_sha;
            array(int|string) result = http_get_safe(url,
                github_auth_headers(), PMP_VERSION);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data) && arrayp(data->commits)) {
                    foreach (data->commits; ; mapping commit) {
                        string msg = (commit->commit
                            && commit->commit->message) || "";
                        // First line only
                        msg = (msg / "\n")[0];
                        string sha_short = sizeof(commit->sha || "") >= 7
                            ? commit->sha[..6] : commit->sha || "";
                        write("  " + sha_short + " " + msg + "\n");
                    }
                    int ahead = data->ahead_by || 0;
                    int behind = data->behind_by || 0;
                    write("pmp: " + ahead + " commits ahead, "
                        + behind + " behind\n");
                } else {
                    info("could not parse compare response");
                }
            } else {
                info("could not fetch compare (HTTP " + result[0] + ")");
            }
            break;
        }
        case "gitlab": {
            string encoded = replace(repo_path, "/", "%2F");
            string url = "https://gitlab.com/api/v4/projects/" + encoded
                         + "/repository/compare?from=" + prev_sha
                         + "&to=" + cur_sha;
            array(int|string) result = http_get_safe(url, 0, PMP_VERSION);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data) && arrayp(data->commits)) {
                    foreach (data->commits; ; mapping commit) {
                        string msg = commit->message || "";
                        msg = (msg / "\n")[0];
                        string sha_short = sizeof(commit->id || "") >= 7
                            ? commit->id[..6] : commit->id || "";
                        write("  " + sha_short + " " + msg + "\n");
                    }
                } else {
                    info("could not parse compare response");
                }
            } else {
                info("could not fetch compare (HTTP " + result[0] + ")");
            }
            break;
        }
        case "selfhosted": {
            info("changelog not available for self-hosted sources "
                + "(no compare API available)");
            break;
        }
    }
}

//! Show which dependencies are outdated.
//! Compares lockfile versions with latest tags from remotes.
void cmd_outdated(mapping ctx) {
    if (!Stdio.exist(ctx["pike_json"]))
        die("no pike.json found");

    // Read lockfile for current versions
    mapping(string:array(string)) lock_map = ([]);
    if (Stdio.exist(ctx["lockfile_path"])) {
        array(array(string)) lf = read_lockfile(ctx["lockfile_path"]);
        foreach (lf; ; array(string) e)
            lock_map[e[0]] = e;
    }

    array(array(string)) deps = parse_deps(ctx["pike_json"]);
    if (sizeof(deps) == 0) {
        info("no dependencies declared");
        return;
    }

    int any_outdated = 0;
    String.Buffer buf = String.Buffer();

    foreach (deps; ; array(string) dep) {
        string name = dep[0];
        string source = dep[1];
        string type = detect_source_type(source);

        if (type == "local") continue;  // Skip local deps

        string repo_path = source_to_repo_path(source);
        string domain = source_to_domain(source);

        // Get current version from lockfile
        string current_tag = "-";
        if (lock_map[name])
            current_tag = lock_map[name][2];

        // Resolve latest tag — uses safe variant that never dies on HTTP errors
        array(string) resolved =
            latest_tag_safe(type, domain, repo_path, PMP_VERSION);
        string latest_tag_str = resolved[0];

        if (sizeof(latest_tag_str) == 0) {
            buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                name, current_tag, "-", "resolve error"));
            any_outdated = 1;
            continue;
        }

        if (latest_tag_str != current_tag && current_tag != "-") {
            string bump = "";
            mapping cur_v = parse_semver(current_tag);
            mapping lat_v = parse_semver(latest_tag_str);
            if (cur_v && lat_v)
                bump = classify_bump(current_tag, latest_tag_str);
            else
                bump = "update";

            string label = bump == "major" ? "MAJOR" : bump;
            buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                name, current_tag, latest_tag_str, label));
            any_outdated = 1;
        } else if (current_tag == "-") {
            buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                name, "(none)", latest_tag_str, "not installed"));
            any_outdated = 1;
        }
    }

    if (any_outdated) {
        write(sprintf("  %-20s %-12s %-12s %s\n",
            "MODULE", "CURRENT", "LATEST", "CHANGE"));
        write(buf->get());
    } else {
        info("all dependencies up to date");
    }
}

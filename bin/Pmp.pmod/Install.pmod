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
inherit .Validate;
inherit .Semver;


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
    string my_pid = (string)getpid();

    for (int attempt = 0; attempt < 2; attempt++) {
        mixed err = catch {
            Stdio.File lf = Stdio.File(lock_path, "wct");
            lf->write(my_pid);
            lf->close();
        };
        if (!err) return;

        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (sizeof(existing) > 0) {
            int pid = (int)existing;
            if (pid > 0) {
                mapping r = Process.run(({"kill", "-0", (string)pid}));
                if (r->exitcode == 0)
                    die("project is locked by pmp process " + pid
                        + " — remove " + lock_path + " manually");
                info("removing stale project lock from process " + pid);
                rm(lock_path);
                continue;
            }
        }
        rm(lock_path);
    }
    die("failed to acquire project lock after retry");
}

//! Release the project-level lock.
void project_unlock(void|string project_root) {
    string lock_path = _project_lock_path(project_root);
    if (Stdio.exist(lock_path)) {
        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (existing == (string)getpid())
            rm(lock_path);
    }}


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

            mapping rmp = resolve_module_path(name, local_path);
            string dest = combine_path(target, rmp->link_name);
            Stdio.mkdirhier(target);
            // Remove existing symlink/dir if present
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(rmp->target, dest);
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
                string resolved = dest;
                mixed rerr = catch { resolved = System.readlink(dest) || dest; };
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
                        ctx["lock_entries"] = lockfile_add_entry(
                            ctx["lock_entries"], name,
                            source_strip_version(source),
                            ver, sha, "");
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
                            ctx["lock_entries"] = lockfile_add_entry(
                                ctx["lock_entries"], name,
                                source_strip_version(source),
                                existing_ver, kept_sha, "");
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
            // Resolve module name from the package's pike.json if available
            string resolved_name = json_field("name", combine_path(entry_full, "pike.json"))
                || name;
            mapping rmp = resolve_module_path(resolved_name, entry_full);
            dest = combine_path(target, rmp->link_name);
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(rmp->target, dest);

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

    int store_locked = 0;

    // Project-level lock: prevents concurrent installs in the same directory
    project_lock(find_project_root());

    // Check if lockfile exists and covers all deps
    int use_lockfile = 0;
    if (Stdio.exist(ctx["lockfile_path"]) && target == ctx["local_dir"]) {
        use_lockfile = 1;
        int lockfile_complete = 1;

        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        array(array(string)) lf_entries = read_lockfile(ctx["lockfile_path"]);
        foreach (deps; ; array(string) dep) {
            if (!lockfile_has_dep(dep[0], ctx["lockfile_path"], dep[1], lf_entries)) {
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
                        mapping rmp = resolve_module_path(ln, local_path);
                        string dest = combine_path(target, rmp->link_name);
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(rmp->target, dest);
                        info("linked " + ln + " -> " + rmp->target);
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
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(rmp->target, dest);
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
            if (ctx["frozen_lockfile"])
                die("frozen lockfile: lockfile does not cover all dependencies — "
                    + "run 'pmp install' without --frozen-lockfile first");
            info("lockfile is stale — re-resolving missing deps");
            use_lockfile = 0;
        }
    }

    if (!use_lockfile) {
        if (ctx["frozen_lockfile"])
            die("frozen lockfile: no lockfile found — "
                + "run 'pmp install' without --frozen-lockfile first");
        if (ctx["offline"])
            die("offline mode: no lockfile found — "
                + "cannot resolve without network");
        // Clean up any symlinks created during lockfile replay
        if (Stdio.is_dir(target)) {
            foreach (get_dir(target) || ({}); ; string name) {
                string full = combine_path(target, name);
                mixed err = catch { System.readlink(full); };
                if (!err) rm(full);
            }
        }

        ctx["lock_entries"] = ({});
        if (!store_locked) store_lock(ctx["store_dir"]);
        store_locked = 1;

        // Atomic install: snapshot existing state, stage new symlinks,
        // then swap atomically on success or rollback on failure.
        string staging = target + ".tmp";
        // Clean up any leftover staging dir from a previous failed run
        if (Stdio.is_dir(staging)) Stdio.recursive_rm(staging);

        // Snapshot existing symlinks for rollback
        mapping(string:string) old_symlinks = ([]);
        if (Stdio.is_dir(target)) {
            foreach (get_dir(target) || ({}); ; string name) {
                string full = combine_path(target, name);
                mixed err = catch {
                    string link = System.readlink(full);
                    if (stringp(link)) old_symlinks[name] = link;
                };
            }
        }

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
                        System.symlink(link, dest);
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
                warn("failed to swap modules directory — staging dir at " + staging);
                Stdio.recursive_rm(backup);
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
                        if (Stdio.is_dir(backup)) mv(backup, target);
                        die("failed to swap modules directory");
                    }
                }
                Stdio.recursive_rm(backup);
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
                if (cp_err)
                    warn("failed to move staging dir to modules");
            }
        }
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
    int global_flag = opts->g || 0;
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
        mixed err = catch {
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
        };
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

    project_lock(find_project_root());
    mixed err = catch {
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
    };
    project_unlock(find_project_root());
    if (err) throw(err);

    // Print update summary
    array(array(string)) new_entries = read_lockfile(ctx["lockfile_path"]);
    print_update_summary(old_entries, new_entries);
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

//! Rollback all modules to the previous lockfile state.
//! Reads pike.lock.prev and re-symlinks modules to those versions.
void cmd_rollback(mapping ctx) {
    string prev_path = ctx["lockfile_path"] + ".prev";
    if (!Stdio.exist(prev_path))
        die("no previous lockfile found (" + prev_path + ")");

    array(array(string)) prev_entries = read_lockfile(prev_path);
    if (sizeof(prev_entries) == 0)
        die("previous lockfile is empty");

    string target = ctx["local_dir"];
    Stdio.mkdirhier(target);

    // Write lockfile atomically before restoring symlinks.
    // If the process crashes mid-rollback, the lockfile reflects
    // the target state so re-running rollback can be safe.
    write_lockfile(ctx["lockfile_path"], prev_entries);

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
                if (Stdio.exist(dest)) rm(dest);
                mapping rmp = resolve_module_path(ln, local_path);
                string dest_rm = combine_path(target, rmp->link_name);
                if (Stdio.exist(dest_rm)) rm(dest_rm);
                System.symlink(rmp->target, dest_rm);
                if (dest != dest_rm) System.symlink(rmp->target, dest);
                info("restored " + ln + " -> " + rmp->target);
            }
        } else {
            // Remote dep — find store entry matching source+tag
            string slug = replace(ls, "/", "-");
            string tag_pattern = slug + "-" + lt + "-*";
            string found_entry = "";
            array(string) candidates = ({});

            if (Stdio.is_dir(ctx["store_dir"])) {
                foreach (get_dir(ctx["store_dir"]) || ({}); ; string se) {
                    if (glob(tag_pattern, se) && Stdio.is_dir(
                            combine_path(ctx["store_dir"], se))) {
                        candidates += ({ se });
                    }
                }
            }

            // Match by content hash from lockfile
            if (sizeof(candidates) > 0 && sizeof(lhash) > 0) {
                foreach (candidates; ; string se) {
                    string stored = read_stored_hash(
                        combine_path(ctx["store_dir"], se));
                    if (stored && stored == lhash) {
                        found_entry = se;
                        break;
                    }
                }
                if (sizeof(found_entry) == 0)
                    warn("no store entry for " + ln + " " + lt
                         + " matches lockfile hash — using first match");
            }

            // Fallback: use first candidate
            if (sizeof(found_entry) == 0 && sizeof(candidates) > 0)
                found_entry = candidates[0];

            if (sizeof(found_entry) == 0) {
                warn("store entry not found for " + ln + " " + lt
                     + " — skipping (store entry may have been pruned)");
                continue;
            }

            string entry_full = combine_path(ctx["store_dir"], found_entry);
            mapping rmp = resolve_module_path(ln, entry_full);
            string dest_rm = combine_path(target, rmp->link_name);
            // Remove both possible old symlinks (bare and .pmod)
            if (Stdio.exist(dest)) rm(dest);
            if (Stdio.exist(dest_rm)) rm(dest_rm);
            System.symlink(rmp->target, dest_rm);
            if (dest != dest_rm) System.symlink(rmp->target, dest);
            info("restored " + ln + " " + lt);
        }
    }


    info("rollback complete — restored " + sizeof(prev_entries) + " modules");
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

        // Resolve latest tag
        mixed err = catch {
            array(string) resolved =
                latest_tag(type, domain, repo_path, PMP_VERSION);
            string latest_tag_str = resolved[0];

            if (sizeof(latest_tag_str) == 0) {
                buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                    name, current_tag, "-", "no tags found"));
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
        };
        if (err) {
            buf->add(sprintf("  %-20s %-12s %-12s %s\n",
                name, current_tag, "-", "resolve error"));
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

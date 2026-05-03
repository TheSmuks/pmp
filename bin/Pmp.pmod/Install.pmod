// Install.pmod — install orchestrators: install_one, cmd_install, cmd_install_all, cmd_install_source
// All state is passed via context mapping (ctx).

import .Config;
import .Helpers;
import .Source;
import .Http;
import .Resolve;
import .Store;
import .Lockfile;
import .Manifest;
import .Semver;
import .Validate;



//! Move directory contents across filesystems (fallback when mv fails).
private void _move_contents(string src, string dst) {
    Stdio.mkdirhier(dst);
    foreach (get_dir(src) || ({}); ; string name)
        mv(combine_path(src, name), combine_path(dst, name));
    Stdio.recursive_rm(src);
}

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

//! Install a single dep from source, including transitive resolution.
void install_one(string name, string source, string target,
                 mapping ctx) {
    string type = detect_source_type(source);

    switch (type) {
        case "local": {
            string local_path = source;
            // Block path traversal before resolving
            if (has_value(local_path, ".."))
                die("local dependency path contains '..' traversal: " + local_path);
            local_path = resolve_local_path(local_path);
            string resolved = System.resolvepath(local_path) || local_path;
            string root = find_project_root();
            if (root && sizeof(root) > 0
                && !has_prefix(resolved, root + "/") && resolved != root)
                die("local dependency path escapes project root: " + source, EXIT_INTERNAL);

            if (!Stdio.is_dir(local_path))
                die("local path not found: " + local_path);

            mapping rmp = resolve_module_path(name, local_path,
                combine_path(local_path, "pike.json"));
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
            // tar is required for github/gitlab tarball extraction
            if (type == "github" || type == "gitlab") {
                if (!Process.search_path("tar"))
                    die("tar is required for " + type + " installs. Install tar or use a self-hosted source.");
            }

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
                if (sizeof(resolved[0]) == 0) {
                    // No tags found — try to resolve the default branch instead
                    array(string) branch_info =
                        resolve_default_branch(type, domain, repo_path, PMP_VERSION);
                    if (sizeof(branch_info[0]) == 0)
                        die("no tags found for " + repo_path
                            + " and could not resolve default branch");
                    ver = branch_info[0];
                } else {
                    ver = resolved[0];
                }

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

                            // Resolve transitive dependencies from the kept version
                            string kept_pkg = combine_path(resolved, "pike.json");
                            if (!Stdio.exist(kept_pkg))
                                kept_pkg = combine_path(version_dir, "pike.json");
                            if (Stdio.exist(kept_pkg)) {
                                array(array(string)) trans_deps =
                                    parse_deps(kept_pkg);
                                foreach (trans_deps; ; array(string) dep) {
                                    info("  transitive: " + dep[0] + " from " + dep[1]);
                                    install_one(dep[0], dep[1], target, ctx);
                                }
                            }
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
            if (has_value(resolved_name, "/") || has_value(resolved_name, "\\")
                || has_value(resolved_name, "..") || has_value(resolved_name, "\0")
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
            mapping rmp = resolve_module_path(resolved_name, entry_full,
                combine_path(entry_full, "pike.json"));
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
    mapping(string:string) old_symlinks = snapshot_symlinks(target);


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

                if (is_local_source(ls)) {
                    // Local dep — just symlink
                    if (sizeof(ls) > 0 && ls != "-") {
                        string local_path = ls;
                        local_path = resolve_local_path(local_path);
                        string resolved = System.resolvepath(local_path) || local_path;
                        string root = find_project_root();
                        if (root && sizeof(root) > 0
                            && !has_prefix(resolved, root + "/") && resolved != root) {
                            warn("local dep " + ln + " path escapes project root: " + ls);
                            continue;
                        }

                        if (!Stdio.is_dir(local_path)) {
                            warn("local dep " + ln + " path "
                                 + local_path + " not found");
                            continue;
                        }
                        Stdio.mkdirhier(target);
                        mapping rmp = resolve_module_path(ln, local_path,
                            combine_path(local_path, "pike.json"));
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

                        // Validate that the store entry exists and has valid structure.
                        // resolve_module_path() checks for name.pmod/ or module.pmod inside
                        // entry_full. If neither exists, the lockfile entry is stale.
                        mapping rmp = resolve_module_path(ln, entry_full,
                            combine_path(entry_full, "pike.json"));
                        if (!Stdio.exist(rmp->target)) {
                            info("lockfile entry for " + ln
                                 + " not in store (stale) — re-resolving");
                            use_lockfile = 0;
                            break;
                        }

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
                    mixed cp_err = catch { _move_contents(staging, target); };
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
                mixed cp_err = catch { _move_contents(staging, target); };
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
        array(array(string)) deps = parse_deps(ctx["pike_json"]);
        ctx["lock_entries"] = prune_stale_deps(ctx["lock_entries"], ctx["store_dir"], ctx["local_dir"], deps);
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
    int global_flag = opts->g || has_value(rest, "-g") || 0;
    // Arg.parse only recognizes flags before the subcommand;
    // also check rest[] for flags placed after the command.
    rest -= ({"-g"});
    if (opts["frozen-lockfile"] || has_value(rest, "--frozen-lockfile"))
        ctx["frozen_lockfile"] = 1;
    rest -= ({"--frozen-lockfile"});
    if (opts->offline || has_value(rest, "--offline"))
        ctx["offline"] = 1;
    rest -= ({"--offline"});
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
        // (must be inside lock to avoid race with concurrent installs)
        project_lock(find_project_root());
        array(array(string)) existing = read_lockfile(ctx["lockfile_path"]);
        int store_locked = 0;
        mixed err = catch {
            store_lock(ctx["store_dir"]);
            store_locked = 1;
            ctx["visited"] = (<>);
            ctx["lock_entries"] = ({});

            // Snapshot existing symlinks so we can roll back new ones
            // if lockfile/manifest writes fail
            mapping(string:string) old_symlinks = snapshot_symlinks(target);

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

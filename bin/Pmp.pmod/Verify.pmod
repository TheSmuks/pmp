//! Verify.pmod — pmp verify: diagnose project and store integrity.
//
// Checks:
//   1. All symlinks in modules/ point to existing store entries
//   2. All store entries have valid .pmp-meta with matching content hashes
//   3. Lockfile entries match installed modules
//   4. Orphaned store entries (not referenced by any project)

inherit .Helpers;
inherit .Store;
inherit .Lockfile;

//! Verify project integrity: symlinks, store, lockfile consistency.
//! Returns 1 if all checks pass, 0 if issues found.
int cmd_verify(mapping ctx) {
    int ok = 1;
    string target = ctx["local_dir"];
    string store_dir = ctx["store_dir"];

    // ── 1. Symlink health ──────────────────────────────────────
    int broken_symlinks = 0;
    int valid_symlinks = 0;
    int skipped = 0;
    if (Stdio.is_dir(target)) {
        foreach (get_dir(target) || ({}); ; string name) {
            string full = combine_path(target, name);
            string link_target;
            mixed err = catch { link_target = System.readlink(full); };
            if (err || !stringp(link_target)) { skipped++; continue; }

            // Resolve relative symlink targets against the symlink's directory
            if (sizeof(link_target) > 0 && link_target[0] != '/') {
                link_target = combine_path(combine_path(full, ".."), link_target);
                mixed rp_err = catch { link_target = System.resolvepath(link_target) || link_target; };
            }
            if (!Stdio.exist(link_target)) {
                warn("broken symlink: " + name + " -> " + link_target);
                broken_symlinks++;
                ok = 0;
                continue;
            }
            // Verify symlink target is within the store directory or project
            // Local deps symlink directly to project dirs, which is valid
            string norm_store = System.resolvepath(store_dir) || combine_path(store_dir, ".");
            if (sizeof(link_target) > 0
                && !has_prefix(link_target, norm_store + "/")
                && link_target != norm_store) {
                // Target is outside store — check if it's a local dep within the project
                string project_root = find_project_root() || getcwd();
                string norm_project = System.resolvepath(project_root) || combine_path(project_root, ".");
                if (!has_prefix(link_target, norm_project + "/")
                    && link_target != norm_project) {
                    warn("symlink target outside store and project: " + name + " -> " + link_target);
                    ok = 0;
                } else {
                    valid_symlinks++;
                }
            } else {
                valid_symlinks++;
            }
        }
    }

    // ── 2. Store entry integrity ───────────────────────────────
    int store_ok = 0;
    int store_broken = 0;
    if (Stdio.is_dir(store_dir)) {
        foreach (get_dir(store_dir) || ({}); ; string ename) {
            string entry = combine_path(store_dir, ename);
            if (!Stdio.is_dir(entry)) continue;

            string meta_file = combine_path(entry, ".pmp-meta");
            if (!Stdio.exist(meta_file)) {
                warn("store entry missing .pmp-meta: " + ename);
                store_broken++;
                ok = 0;
                continue;
            }

            // Verify content hash — missing hash is an integrity issue
            string stored_hash = read_stored_hash(entry);
            if (!stored_hash || sizeof(stored_hash) == 0) {
                warn("store entry missing content_sha256: " + ename);
                store_broken++;
                ok = 0;
                continue;
            }
            string actual_hash = compute_dir_hash(entry);
            if (stored_hash != actual_hash) {
                warn("store entry hash mismatch: " + ename
                     + " (stored: " + stored_hash[..15] + "..."
                     + " actual: " + actual_hash[..15] + "...)");
                store_broken++;
                ok = 0;
                continue;
            }
            store_ok++;
        }
    }

    // ── 3. Lockfile consistency ────────────────────────────────
    int lockfile_orphans = 0;
    int lockfile_missing = 0;
    if (Stdio.exist(ctx["lockfile_path"])) {
        array(array(string)) entries = read_lockfile(ctx["lockfile_path"]);
        foreach (entries; ; array(string) e) {
            string ln = e[0];
            if (sizeof(ln) == 0) continue;

            string link_path = combine_path(target, ln);
            string link_path_pmod = combine_path(target, ln + ".pmod");

            if (!Stdio.exist(link_path) && !Stdio.exist(link_path_pmod)) {
                warn("lockfile entry '" + ln + "' not installed in modules/");
                lockfile_missing++;
                ok = 0;
            }
        }

        // Check for modules not in lockfile
        mapping(string:int) lock_names = ([]);
        foreach (entries; ; array(string) e)
            if (sizeof(e[0]) > 0) lock_names[e[0]] = 1;

        if (Stdio.is_dir(target)) {
            foreach (get_dir(target) || ({}); ; string name) {
                string bare = has_suffix(name, ".pmod") ? name[..<5] : name;
                if (!lock_names[bare]) {
                    warn("module '" + name + "' installed but not in lockfile");
                    lockfile_orphans++;
                    ok = 0;
                }
            }
        }
    }

    // ── 4. Orphaned store entries ──────────────────────────────
    int store_orphans = 0;
    if (Stdio.is_dir(store_dir) && Stdio.exist(ctx["lockfile_path"])) {
        // Build set of store entries referenced by lockfile
        multiset(string) referenced = (<>);
        array(array(string)) lf = read_lockfile(ctx["lockfile_path"]);
        foreach (lf; ; array(string) e) {
            string ls = e[1], lt = e[2];
            if (sizeof(ls) > 0 && ls != "-" && !has_prefix(ls, "./") && !has_prefix(ls, "/")) {
                string slug = replace(ls, "/", "-");
                string pattern = slug + "-" + lt + "-*";
                foreach (get_dir(store_dir) || ({}); ; string se)
                    if (glob(pattern, se)) referenced[se] = 1;
            }
        }
        // Check for unreferenced entries
        foreach (get_dir(store_dir) || ({}); ; string ename) {
            string entry = combine_path(store_dir, ename);
            if (!Stdio.is_dir(entry)) continue;
            if (!referenced[ename]) {
                // Not referenced by current project — may be used by other projects
                // so this is informational only
                store_orphans++;
            }
        }
    }
    // ── Summary ────────────────────────────────────────────────
    write(sprintf("  symlinks:    %d ok, %d broken, %d skipped\n", valid_symlinks, broken_symlinks, skipped));
    write(sprintf("  store:       %d ok, %d broken, %d orphaned\n", store_ok, store_broken, store_orphans));
    write(sprintf("  lockfile:    %d missing, %d orphaned\n",
        lockfile_missing, lockfile_orphans));

    if (ok)
        info("all checks passed");
    else
        warn("issues detected — see above for details");

    return ok;
}

//! Check environment health: pike binary, PATH, tokens, store, disk.
//! Returns 1 if all checks pass, 0 if issues found.
int cmd_doctor(mapping ctx) {
    int ok = 1;

    // ── 1. Pike binary ───────────────────────────────────────
    string pike_bin = ctx["pike_bin"];
    if (Stdio.exist(pike_bin)) {
        mapping r = Process.run(({pike_bin, "--version"}));
        string ver = (r->stderr || r->stdout || "");
        // First line has the version
        ver = (ver / "\n")[0];
        write(sprintf("  pike:        %s\n", ver));
    } else {
        warn("pike binary not found: " + pike_bin);
        ok = 0;
    }

    // ── 2. Git ──────────────────────────────────────────────────
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    string git_bin = Process.locate_binary(search_path, "git");
    if (git_bin) {
        write(sprintf("  git:         %s\n", git_bin));
    } else {
        warn("git not found in PATH");
        ok = 0;
    }

    // ── 3. Tokens ──────────────────────────────────────────────
    string gh_token = getenv("GITHUB_TOKEN") || "";
    string gl_token = getenv("GITLAB_TOKEN") || "";
    if (sizeof(gh_token) > 0)
        write(sprintf("  GITHUB_TOKEN: set (%d chars)\n", sizeof(gh_token)));
    else
        write("  GITHUB_TOKEN: not set (public repos only)\n");
    if (sizeof(gl_token) > 0)
        write(sprintf("  GITLAB_TOKEN: set (%d chars)\n", sizeof(gl_token)));

    // ── 4. Store directory ──────────────────────────────────────
    string store_dir = ctx["store_dir"];
    if (Stdio.is_dir(store_dir)) {
        int entries = 0;
        foreach (get_dir(store_dir) || ({}); ; string f)
            if (Stdio.is_dir(combine_path(store_dir, f))) entries++;
        // Check write permission
        string test_file = combine_path(store_dir, ".doctor_test");
        mixed write_err = catch { Stdio.write_file(test_file, "x"); rm(test_file); };
        if (write_err) {
            warn("store directory not writable: " + store_dir);
            ok = 0;
        } else {
            write(sprintf("  store:       %s (%d entries, writable)\n", store_dir, entries));
        }
    } else {
        write(sprintf("  store:       %s (not created yet)\n", store_dir));
    }

    // ── 5. Project ──────────────────────────────────────────────
    string root = find_project_root();
    if (root) {
        write(sprintf("  project:     %s\n", root));
        if (Stdio.exist(combine_path(root, "pike.lock")))
            write("  lockfile:    present\n");
        else
            write("  lockfile:    not found\n");
    } else {
        write("  project:     no pike.json found\n");
    }

    if (ok)
        info("environment healthy");
    else
        warn("issues detected — see above for details");

    return ok;
}
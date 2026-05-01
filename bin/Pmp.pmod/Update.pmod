// Update.pmod — update and outdated commands.
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
import .Install;

//! Print update summary table comparing old and new lockfile entries.
void print_update_summary(array(array(string)) old_entries,
                           array(array(string)) new_entries) {
    // Build lookup from name -> entry
    mapping(string:array(string)) old_map = mkmapping(column(old_entries, 0), old_entries);

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

            // Prune stale transitive deps
            ctx["lock_entries"] = prune_stale_deps(ctx["lock_entries"], ctx["store_dir"], ctx["local_dir"], deps);
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

//! Show which dependencies are outdated.
//! Compares lockfile versions with latest tags from remotes.
void cmd_outdated(mapping ctx) {
    if (!Stdio.exist(ctx["pike_json"]))
        die("no pike.json found");

    if (ctx["offline"]) {
        info("offline mode: cannot check for outdated dependencies");
        return;
    }

    // Read lockfile for current versions
    mapping(string:array(string)) lock_map = ([]);
    if (Stdio.exist(ctx["lockfile_path"])) {
        array(array(string)) lf = read_lockfile(ctx["lockfile_path"]);
        lock_map = mkmapping(column(lf, 0), lf);
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

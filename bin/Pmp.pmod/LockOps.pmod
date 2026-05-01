// LockOps.pmod — lock, rollback, and changelog commands.
// All state is passed via context mapping (ctx).

import .Config;
import .Helpers;
import .Http;
import .Resolve;
import .Store;
import .Lockfile;
import .Manifest;
import .Source;
import .Semver;
import .Install;

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

            if (is_local_source(ls)) {
                // Local dep — re-symlink
                if (sizeof(ls) > 0 && ls != "-") {
                    string local_path = ls;
                    local_path = resolve_local_path(local_path);
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

        int failed_count = sizeof(prev_entries) - sizeof(restored_entries);

        info(sprintf("rollback complete — restored %d of %d modules",
            sizeof(restored_entries), sizeof(prev_entries)));
        if (failed_count > 0) {
            multiset(string) restored_names = (<>);
            foreach (restored_entries; ; array(string) e)
                restored_names[e[0]] = 1;
            foreach (prev_entries; ; array(string) e)
                if (sizeof(e[0]) > 0 && !restored_names[e[0]])
                    warn("  failed to restore: " + e[0]);
        }
    };
    store_unlock(ctx["store_dir"]);
    project_unlock(find_project_root());
    if (err) throw(err);
}

private void _print_commit_entry(mapping commit, string sha_field) {
    string msg = commit->message || "";
    msg = (msg / "\n")[0];
    string sha = commit[sha_field] || "";
    string sha_short = sizeof(sha) >= 7 ? sha[..6] : sha;
    write("  " + sha_short + " " + msg + "\n");
}

//! Show changes between versions for a specific module.
//! Compares current lockfile with .prev lockfile.
void cmd_changelog(array(string) args, mapping ctx) {
    if (ctx["offline"]) {
        info("offline mode: cannot fetch changelog");
        return;
    }

    if (sizeof(args) == 0)
        die("usage: pmp changelog <module>");

    string mod_name = args[0];
    string prev_path = ctx["lockfile_path"] + ".prev";

    array(array(string)) current = read_lockfile(ctx["lockfile_path"]);
    array(array(string)) prev = read_lockfile(prev_path);

    // Find module in both lockfiles
    mapping(string:array(string)) cur_map = mkmapping(column(current, 0), current);
    mapping(string:array(string)) prev_map = mkmapping(column(prev, 0), prev);
    array(string) cur_entry = cur_map[mod_name];
    array(string) prev_entry = prev_map[mod_name];

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
                    foreach (data->commits; ; mapping c) {
                        // Flatten nested GitHub structure
                        if (!c->message && c->commit && c->commit->message)
                            c->message = c->commit->message;
                        _print_commit_entry(c, "sha");
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
            string encoded = Protocols.HTTP.percent_encode(repo_path);
            string url = "https://gitlab.com/api/v4/projects/" + encoded
                         + "/repository/compare?from=" + prev_sha
                         + "&to=" + cur_sha;
            array(int|string) result = http_get_safe(url, 0, PMP_VERSION);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data) && arrayp(data->commits)) {
                    foreach (data->commits; ; mapping c)
                        _print_commit_entry(c, "id");
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

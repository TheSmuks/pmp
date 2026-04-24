// Project.pmod — project-level commands: init, list, clean, remove.
// All state is passed via context mapping (ctx).

inherit .Helpers;
inherit .Lockfile;
inherit .Manifest;

void cmd_init(mapping ctx) {
    if (Stdio.exist(ctx["pike_json"]))
        die("pike.json already exists in this directory");

    // Extract project name from current working directory
    string dir_name = (getcwd() / "/")[-1];
    if (!sizeof(dir_name) || dir_name == ".")
        dir_name = basename(getcwd());
    if (!sizeof(dir_name)) dir_name = "my-project";

    string content = sprintf("{\n  \"name\": %s,\n  \"version\": \"0.1.0\",\n  \"dependencies\": {}\n}\n",
        Standards.JSON.encode(dir_name));
    int bytes = Stdio.write_file(ctx["pike_json"], content);
    if (bytes != sizeof(content))
        die("failed to write pike.json (wrote " + bytes + " of " + sizeof(content) + " bytes)");
    info("created pike.json");
}

void cmd_list(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    string dir = opts->g ? ctx["global_dir"] : ctx["local_dir"];
    int json_output = opts->json || 0;

    if (!Stdio.is_dir(dir)) {
        if (json_output) write("[]\n");
        else info("no modules installed");
        return;
    }

    if (json_output) {
        array(mapping) entries = ({});
        foreach (get_dir(dir) || ({}); ; string mod_name) {
            string moddir = combine_path(dir, mod_name);
            if (!Stdio.is_dir(moddir)) continue;
            string show_name = display_name(mod_name);
            entries += ({ (["name": show_name]) });
        }
        write(Standards.JSON.encode(entries, Standards.JSON.HUMAN_READABLE) + "\n");
        return;
    }
    int found = 0;
    foreach (get_dir(dir) || ({}); ; string mod_name) {
        string moddir = combine_path(dir, mod_name);
        if (!Stdio.is_dir(moddir)) continue;

        // Display name strips .pmod suffix
        string show_name = display_name(mod_name);

        string ver = "(unknown)";
        // Resolve .version through symlink to store entry root
        string real_dir = get_symlink_target(moddir) || moddir;
        string ver_file = combine_path(real_dir, ".version");
        // If symlink points inside store entry (e.g., to subdir), try parent
        if (!Stdio.exist(ver_file) && has_suffix(mod_name, ".pmod"))
            ver_file = combine_path(real_dir, "..", ".version");
        if (Stdio.exist(ver_file))
            ver = Stdio.read_file(ver_file) || "(unknown)";

        string src = "";
        string link = get_symlink_target(moddir);
        if (link && has_prefix(link, ctx["store_dir"])) {
            src = " (store: " + (link / "/")[-1] + ")";
        } else if (link) {
            src = " -> " + link;
        }

        write(sprintf("  %-20s %-12s%s\n", show_name, ver, src));
        found = 1;
    }

    if (!found) info("no modules installed");
}

void cmd_clean(mapping ctx) {
    if (!Stdio.is_dir(ctx["local_dir"])) {
        info("nothing to clean");
        return;
    }
    int count = 0;
    int has_non_symlink = 0;
    foreach (get_dir(ctx["local_dir"]) || ({}); ; string name) {
        string full = combine_path(ctx["local_dir"], name);
        if (is_symlink(full)) {
            // Symlink — safe to remove
            count++;
        } else {
            // Real file or directory — preserve
            has_non_symlink = 1;
        }
    }
    // Remove only symlink entries, preserve real content
    foreach (get_dir(ctx["local_dir"]) || ({}); ; string name) {
        string full = combine_path(ctx["local_dir"], name);
        if (is_symlink(full)) rm(full);
    }
    if (!has_non_symlink) {
        // All content was symlinks — remove the directory too
        Stdio.recursive_rm(ctx["local_dir"]);
    }
    info(sprintf("cleaned %d module%s from %s, store preserved",
        count, count == 1 ? "" : "s", ctx["local_dir"]));
}

void cmd_remove(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    if (sizeof(rest) == 0)
        die("usage: pmp remove <name>");
    string name = rest[0];
    // Strip .pmod suffix — users may pass "Foo.pmod" but pike.json keys are bare names
    if (has_suffix(name, ".pmod")) name = name[..<5];
    // Path traversal protection
    if (search(name, "/") >= 0 || search(name, "..") >= 0 || search(name, "\0") >= 0)
        die("invalid module name: " + name);
    string lock_path = combine_path(find_project_root() || getcwd(), ".pmp-install.lock");
    advisory_lock(lock_path, "project");
    register_project_lock_path(lock_path);


    // --- Validate phase: ensure files are readable before we touch anything ---
    string pike_json_path = ctx["pike_json"];
    string lockfile_path = ctx["lockfile_path"];
    string pike_json_raw = 0;
    if (Stdio.exist(pike_json_path)) {
        pike_json_raw = Stdio.read_file(pike_json_path);
        if (!pike_json_raw)
            die("cannot read " + pike_json_path);
    }
    string lockfile_raw = 0;
    if (Stdio.exist(lockfile_path)) {
        lockfile_raw = Stdio.read_file(lockfile_path);
        if (!lockfile_raw)
            die("cannot read " + lockfile_path);
    }

    // Pre-check that name exists somewhere
    int found = 0;
    if (pike_json_raw) {
        mixed data;
        mixed jerr = catch { data = Standards.JSON.decode(pike_json_raw); };
        if (!jerr && mappingp(data) && mappingp(data->dependencies)
            && !zero_type(data->dependencies[name]))
            found = 1;
    }
    string link = combine_path(ctx["local_dir"], name);
    string link_pmod = combine_path(ctx["local_dir"], name + ".pmod");
    if (Stdio.exist(link) || Stdio.exist(link_pmod))
        found = 1;
    if (lockfile_raw) {
        array(array(string)) entries = read_lockfile(lockfile_path);
        foreach (entries; ; array(string) e)
            if (e[0] == name) { found = 1; break; }
    }
    if (!found)
        die("nothing to remove: " + name + " not found");

    // Snapshot symlink targets for rollback
    mapping(string:string) old_symlink_targets = ([]);
    if (Stdio.exist(link)) {
        string target = get_symlink_target(link);
        if (target) old_symlink_targets[link] = target;
    }
    if (Stdio.exist(link_pmod)) {
        string target = get_symlink_target(link_pmod);
        if (target) old_symlink_targets[link_pmod] = target;
    }

    // --- Execute phase with rollback on failure ---
    mixed err = catch {
        // 1. Update pike.json
        if (pike_json_raw) {
            mixed data;
            mixed jerr = catch { data = Standards.JSON.decode(pike_json_raw); };
            if (!jerr && mappingp(data) && mappingp(data->dependencies)
                && !zero_type(data->dependencies[name])) {
                m_delete(data->dependencies, name);
                atomic_write(pike_json_path,
                    Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");
                info("removed " + name + " from pike.json");
            }
        }

        // 2. Remove symlinks
        if (Stdio.exist(link)) {
            rm(link);
            info("removed " + link);
        }
        if (Stdio.exist(link_pmod)) {
            rm(link_pmod);
            info("removed " + link_pmod);
        }

        // 3. Update lockfile (only if dep was actually present)
        if (lockfile_raw) {
            array(array(string)) entries = read_lockfile(lockfile_path);
            array(array(string)) new_entries = ({});
            int had_entry = 0;
            foreach (entries; ; array(string) e)
                if (e[0] != name) new_entries += ({ e });
                else had_entry = 1;
            if (had_entry) {
                ctx["lock_entries"] = new_entries;
                write_lockfile(lockfile_path, ctx["lock_entries"]);
            }
        }
    };
    if (err) {
        // Restore symlinks first
        foreach (old_symlink_targets; string path; string target) {
            catch { atomic_symlink(target, path); };
        }
        // Then restore files
        catch { if (pike_json_raw) atomic_write(pike_json_path, pike_json_raw); };
        catch { if (lockfile_raw) atomic_write(lockfile_path, lockfile_raw); };
        werror("pmp: remove failed, rolled back to previous state\n");
        advisory_unlock(lock_path);
        die(describe_error(err));
    }
    advisory_unlock(lock_path);
}

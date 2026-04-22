// Project.pmod — project-level commands: init, list, clean, remove.
// All state is passed via context mapping (ctx).

inherit .Helpers;
inherit .Lockfile;
inherit .Manifest;

void cmd_init(mapping ctx) {
    if (Stdio.exist(ctx["pike_json"]))
        die("pike.json already exists in this directory");

    string content = "{\n  \"dependencies\": {}\n}\n";
    Stdio.write_file(ctx["pike_json"], content);
    info("created pike.json");
}

void cmd_list(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    string dir = opts->g ? ctx["global_dir"] : ctx["local_dir"];

    if (!Stdio.is_dir(dir)) {
        info("no modules installed");
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
        string real_dir = moddir;
        mixed rerr = catch { real_dir = System.readlink(moddir) || moddir; };
        string ver_file = combine_path(real_dir, ".version");
        // If symlink points inside store entry (e.g., to subdir), try parent
        if (!Stdio.exist(ver_file) && has_suffix(mod_name, ".pmod"))
            ver_file = combine_path(real_dir, "..", ".version");
        if (Stdio.exist(ver_file))
            ver = Stdio.read_file(ver_file) || "(unknown)";

        string src = "";
        mixed err = catch {
            string link = System.readlink(moddir);
            if (link && has_prefix(link, ctx["store_dir"])) {
                src = " (store: " + (link / "/")[-1] + ")";
            } else if (link) {
                src = " -> " + link;
            }
        };

        write(sprintf("  %-20s %-12s%s\n", show_name, ver, src));
        found = 1;
    }

    if (!found) info("no modules installed");
}

void cmd_clean(mapping ctx) {
    if (Stdio.is_dir(ctx["local_dir"])) {
        Stdio.recursive_rm(ctx["local_dir"]);
        info("removed " + ctx["local_dir"] + " (store preserved)");
    } else {
        info("nothing to clean");
    }
}

void cmd_remove(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    if (sizeof(rest) == 0)
        die("usage: pmp remove <name>");
    string name = rest[0];
    int removed = 0;

    // Remove from pike.json
    if (Stdio.exist(ctx["pike_json"])) {
        string raw = Stdio.read_file(ctx["pike_json"]);
        if (raw) {
            mixed data;
            mixed err = catch { data = Standards.JSON.decode(raw); };
            if (!err && mappingp(data) && mappingp(data->dependencies)) {
                if (!zero_type(data->dependencies[name])) {
                    m_delete(data->dependencies, name);
                    Stdio.write_file(ctx["pike_json"],
                        Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");
                    info("removed " + name + " from pike.json");
                    removed = 1;
                }
            }
        }
    }

    // Remove symlink (try both bare name and .pmod suffix)
    string link = combine_path(ctx["local_dir"], name);
    string link_pmod = combine_path(ctx["local_dir"], name + ".pmod");
    if (Stdio.exist(link)) {
        rm(link);
        info("removed " + link);
        removed = 1;
    }
    if (Stdio.exist(link_pmod)) {
        rm(link_pmod);
        info("removed " + link_pmod);
        removed = 1;
    }

    // Update lockfile
    if (Stdio.exist(ctx["lockfile_path"])) {
        array(array(string)) entries = read_lockfile(ctx["lockfile_path"]);
        array(array(string)) new_entries = ({});
        int had_entry = 0;
        foreach (entries; ; array(string) e)
            if (e[0] != name) new_entries += ({ e });
            else had_entry = 1;
        if (had_entry) removed = 1;
        ctx["lock_entries"] = new_entries;
        write_lockfile(ctx["lockfile_path"], ctx["lock_entries"]);
    }

    if (!removed)
        warn("nothing to remove: " + name + " not found");
}

// StoreCmd.pmod — cmd_store: inspect and prune the content-addressable store.
// All state is passed via context mapping (ctx).

inherit .Helpers;
inherit .Store;

private int(0..1) _entry_referenced(string store_dir, string entry_name, string modules_dir) {
    if (!Stdio.is_dir(modules_dir)) return 0;
    string entry = combine_path(store_dir, entry_name);
    foreach (get_dir(modules_dir) || ({}); ; string lname) {
        string link = combine_path(modules_dir, lname);
        string target = get_symlink_target(link);
        if (target) {
            if (target[0] != '/') {
                target = combine_path(combine_path(link, ".."), target);
                catch { target = System.resolvepath(target) || target; };
            }
            if (has_prefix(target, entry + "/") || target == entry)
                return 1;
        }
    }
    return 0;
}

int dir_size(string path) {
    int total = 0;
    foreach (get_dir(path) || ({}); ; string name) {
        string full = combine_path(path, name);
        if (Stdio.is_link(full)) continue;
        Stdio.Stat st = file_stat(full);
        if (!st) continue;
        if (st->isdir) total += dir_size(full);
        else total += st->size;
    }
    return total;
}

string human_size(int bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return sprintf("%.1f KB", (float)bytes / 1024.0);
    if (bytes < 1024 * 1024 * 1024) return sprintf("%.1f MB", (float)bytes / (1024.0 * 1024.0));
    return sprintf("%.1f GB", (float)bytes / (1024.0 * 1024.0 * 1024.0));
}

void cmd_store(array(string) args, mapping ctx) {
    mapping opts = Arg.parse(({"pmp"}) + args);
    array(string) rest = opts[Arg.REST];
    string subcmd = sizeof(rest) > 0 ? rest[0] : "";

    switch (subcmd) {
        case "prune": {
            if (!Stdio.is_dir(ctx["store_dir"])) {
                info("no store directory");
                return;
            }
            store_lock(ctx["store_dir"]);
            int force = opts->force || opts->f || 0;
            array(string) entries = filter(get_dir(ctx["store_dir"]) || ({}),
                lambda(string ename) { return Stdio.is_dir(combine_path(ctx["store_dir"], ename)); });
            if (!Stdio.is_dir(ctx["local_dir"])) {
                info("no local modules directory found \u2014 skipping prune");
                store_unlock(ctx["store_dir"]);
                return;
            }
            array(string) unused = filter(entries,
                lambda(string ename) {
                    return !_entry_referenced(ctx["store_dir"], ename, ctx["local_dir"])
                        && !_entry_referenced(ctx["store_dir"], ename, ctx["global_dir"]);
                });

            if (sizeof(unused) == 0) {
                info("no unused entries found");
                store_unlock(ctx["store_dir"]);
                return;
            }

            // Report unused entries
            foreach (unused; ; string ename)
                info("unused store entry: " + ename);

            if (force) {
                foreach (unused; ; string ename) {
                    string entry = combine_path(ctx["store_dir"], ename);
                    Stdio.recursive_rm(entry);
                    info("removed " + ename);
                }
                info(sprintf("pruned %d entries", sizeof(unused)));
                store_unlock(ctx["store_dir"]);
            } else {
                info(sprintf("%d unused entries (use --force to delete)",
                    sizeof(unused)));
                store_unlock(ctx["store_dir"]);
            }
            break;
        }
        case "": {
            // Show store status
            if (!Stdio.is_dir(ctx["store_dir"])) {
                info("store is empty (" + ctx["store_dir"] + ")");
                return;
            }
            int count = 0;
            int total_size = 0;
            foreach (get_dir(ctx["store_dir"]) || ({}); ; string ename) {
                string entry = combine_path(ctx["store_dir"], ename);
                if (!Stdio.is_dir(entry)) continue;

                string tag = read_meta_field(entry, "tag") || "";

                int esize_bytes = dir_size(entry);
                total_size += esize_bytes;
                string esize = human_size(esize_bytes);

                write(sprintf("  %-55s %s\n", ename, esize));
                count++;
            }
            string total = human_size(total_size);
            write(sprintf("\n  %d entries, %s total\n", count, total));
            break;
        }
        default:
            die("unknown store subcommand: " + subcmd);
    }
}

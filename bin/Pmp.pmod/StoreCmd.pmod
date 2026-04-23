// StoreCmd.pmod — cmd_store: inspect and prune the content-addressable store.
// All state is passed via context mapping (ctx).

inherit .Helpers;

int dir_size(string path) {
    int total = 0;
    foreach (get_dir(path) || ({}); ; string name) {
        string full = combine_path(path, name);
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
            int force = opts->force || opts->f || 0;
            array(string) unused = ({});
            foreach (get_dir(ctx["store_dir"]) || ({}); ; string ename) {
                string entry = combine_path(ctx["store_dir"], ename);
                if (!Stdio.is_dir(entry)) continue;

                if (Stdio.is_dir(ctx["local_dir"])) {
                    int found = 0;
                    foreach (get_dir(ctx["local_dir"]) || ({}); ;
                             string lname) {
                        string link = combine_path(ctx["local_dir"], lname);
                        string target = get_symlink_target(link);
                        if (target && (has_suffix(target, "/" + ename) || target == ename)) {
                            found = 1;
                            break;
                        }
                    }
                    if (!found && ctx["global_dir"] && Stdio.is_dir(ctx["global_dir"])) {
                        foreach (get_dir(ctx["global_dir"]) || ({}); ; string lname) {
                            string link = combine_path(ctx["global_dir"], lname);
                            string target = get_symlink_target(link);
                            if (target && (has_suffix(target, "/" + ename) || target == ename)) {
                                found = 1;
                                break;
                            }
                        }
                    }
                    if (!found)
                        unused += ({ ename });
                } else {
                    info("no local modules directory found — skipping prune");
                    return;
                }
            }

            if (sizeof(unused) == 0) {
                info("no unused entries found");
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
            } else {
                info(sprintf("%d unused entries (use --force to delete)",
                    sizeof(unused)));
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

                string tag = "";
                string meta_file =
                    combine_path(entry, ".pmp-meta");
                if (Stdio.exist(meta_file)) {
                    string meta = Stdio.read_file(meta_file);
                    foreach (meta / "\n"; ; string line) {
                        if (has_prefix(line, "tag\t"))
                            tag = line[4..];
                    }
                }

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

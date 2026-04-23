// StoreCmd.pmod — cmd_store: inspect and prune the content-addressable store.
// All state is passed via context mapping (ctx).

inherit .Helpers;

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
                        mixed err = catch {
                            string target = System.readlink(link);
                            if (target && (has_suffix(target, "/" + ename) || target == ename)) {
                                found = 1;
                                break;
                            }
                        };
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

                // Get size using du
                mapping r = Process.run(
                    ({"du", "-sh", entry}));
                string esize = "";
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    esize = (r->stdout / "\t")[0];

                write(sprintf("  %-55s %s\n", ename, esize));
                count++;
            }
            // Total size
            mapping r = Process.run(({"du", "-sh", ctx["store_dir"]}));
            string total = "";
            if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                total = (r->stdout / "\t")[0];
            write(sprintf("\n  %d entries, %s total\n", count, total));
            break;
        }
        default:
            die("unknown store subcommand: " + subcmd);
    }
}

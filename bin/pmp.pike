#!/usr/bin/env pike
// pmp — Pike Module Package Manager
// Entry point — config init, context creation, command dispatch.
// Commands and orchestrators live in bin/Pmp.pmod/*.pmod

import Pmp;
import Arg;

void cmd_version() {
    info("pmp v" + PMP_VERSION);
}

void print_help() {
    write("pmp — Pike Module Package Manager\n\n");
    write("Usage:\n");
    write("  pmp init                                    "
          "Create pike.json\n");
    write("  pmp install                                 "
          "Install all deps (from lockfile or pike.json)\n");
    write("  pmp install <url>                           "
          "Add and install dependency\n");
    write("  pmp install <url>#tag                       "
          "Install specific version\n");
    write("  pmp install ./local/path                    "
          "Local dependency (symlinked)\n");
    write("  pmp install -g <url>                        "
          "Install system-wide\n");
    write("  pmp update [module]                         "
          "Update deps to latest tags\n");
    write("  pmp lock                                    "
          "Write pike.lock\n");
    write("  pmp store                                   "
          "Show store entries and disk usage\n");
    write("  pmp store prune                             "
          "Show unused store entries\n");
    write("  pmp list [-g]                               "
          "Show installed dependencies\n");
    write("  pmp env                                     "
          "Create .pike-env/ virtual environment\n");
    write("  pmp clean                                   "
          "Remove ./modules/ (keeps store)\n");
    write("  pmp remove <name>                         "
          "Remove a dependency\n");
    write("  pmp run <script>                            "
          "Run script with module paths\n");
    write("  pmp version                                 "
          "Show version\n");
    write("\nSource formats:\n");
    write("  github.com/owner/repo                       "
          "GitHub\n");
    write("  gitlab.com/owner/repo                       "
          "GitLab\n");
    write("  git.example.com/owner/repo                  "
          "Self-hosted git\n");
    write("  ./local/path or /abs/path                   "
          "Local module\n");
}

int main(int argc, array(string) argv) {
    // Configuration
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    string pike_bin = getenv("PIKE_BIN")
        || Process.locate_binary(search_path, "pike8.0")
        || Process.locate_binary(search_path, "pike")
        || "/usr/local/pike/8.0.1116/bin/pike";
    string global_dir = combine_path(getenv("HOME") || "/tmp", ".pike/modules");
    string local_dir = "./modules";
    string store_dir = combine_path(getenv("HOME") || "/tmp", ".pike/store");
    string pike_json = "./pike.json";
    string lockfile_path = "./pike.lock";

    // Shared context — passed by reference to all command modules
    mapping ctx = ([
        "pike_bin": pike_bin,
        "global_dir": global_dir,
        "local_dir": local_dir,
        "store_dir": store_dir,
        "pike_json": pike_json,
        "lockfile_path": lockfile_path,
        "lock_entries": ({ }),
        "visited": (<>),
        "std_libs": init_std_libs(),
    ]);

    mapping opts = Arg.parse(argv);
    array(string) rest = opts[Arg.REST];

    if (opts->help) { print_help(); return 0; }
    if (opts->version) { cmd_version(); return 0; }
    if (sizeof(rest) == 0) { print_help(); return 0; }

    string cmd = rest[0];
    array(string) args = rest[1..];

    switch (cmd) {
        case "init":     cmd_init(ctx); break;
        case "install":  cmd_install(args, ctx); break;
        case "update":   cmd_update(args, ctx); break;
        case "lock":     cmd_lock(ctx); break;
        case "store":    cmd_store(args, ctx); break;
        case "list":     cmd_list(args, ctx); break;
        case "clean":    cmd_clean(ctx); break;
        case "remove":   cmd_remove(args, ctx); break;
        case "run":      cmd_run(args, ctx); break;
        case "env":      cmd_env(ctx); break;
        case "version":  cmd_version(); break;
        default:
            die("unknown command '" + cmd + "' (try: pmp --help)");
    }
    return 0;
}

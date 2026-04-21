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
    write("  pmp rollback                                "
          "Rollback to previous lockfile\n");
    write("  pmp changelog <module>                      "
          "Show changes between versions\n");
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
    write("  pmp resolve [module]                       "
          "Print resolved module paths\n");
    write("  pmp version                                 "
          "Show version\n");
    write("  pmp self-update                            "
          "Update pmp to the latest version\n");
    write("\nSource formats:\n");
    write("  github.com/owner/repo                       "
          "GitHub\n");
    write("  gitlab.com/owner/repo                       "
          "GitLab\n");
    write("  git.example.com/owner/repo                  "
          "Self-hosted git\n");
    write("  ./local/path or /abs/path                   "
          "Local module\n");
    write("\nVersion resolution uses Semantic Versioning (https://semver.org/).\n");
    write("Only tags matching MAJOR.MINOR.PATCH are sorted correctly.\n");
}

void cmd_self_update(mapping ctx) {
    // Resolve the pmp repo root from the running script location.
    // __FILE__ is /path/to/pmp/bin/pmp.pike — go up two levels to reach the repo root.
    string pmp_dir = combine_path(__FILE__, "../..");
    string git_dir = combine_path(pmp_dir, ".git");

    // Verify we're in a git checkout
    if (!Stdio.exist(git_dir)) {
        die("not installed via git — re-run: curl -LsSf https://github.com/TheSmuks/pmp/install.sh | sh");
    }

    // Check for local modifications
    mapping status_res = Process.run(({"git", "status", "--porcelain"}), (["cwd": pmp_dir]));
    string status_out = String.trim_all_whites(status_res->stdout || "");
    if (sizeof(status_out) > 0) {
        warn("local modifications detected — aborting self-update");
        die("commit or stash your changes before updating");
    }

    // Fetch tags
    info("checking for updates...");
    mapping fetch_res = Process.run(({"git", "fetch", "--tags"}), (["cwd": pmp_dir]));
    if (fetch_res->exitcode != 0) {
        die("failed to fetch updates — check your internet connection");
    }

    // Get the SHA of the latest tagged commit
    mapping rev_res = Process.run(({"git", "rev-list", "--tags", "--max-count=1"}), (["cwd": pmp_dir]));
    string rev = String.trim_all_whites(rev_res->stdout || "");
    if (rev == "") {
        die("no tags found in the repository");
    }

    // Resolve that SHA to a tag name
    mapping tag_res = Process.run(({"git", "describe", "--tags", rev}), (["cwd": pmp_dir]));
    string latest_tag = String.trim_all_whites(tag_res->stdout || "");
    if (latest_tag == "") {
        die("could not determine latest version");
    }

    string current = PMP_VERSION;
    // Strip 'v' prefix for comparison
    string current_clean = has_prefix(current, "v") ? current[1..] : current;
    string latest_clean = has_prefix(latest_tag, "v") ? latest_tag[1..] : latest_tag;

    if (current_clean == latest_clean) {
        info("pmp is up to date (v" + current_clean + ")");
        return;
    }

    // Checkout the latest tag
    mapping checkout_res = Process.run(({"git", "checkout", latest_tag}), (["cwd": pmp_dir]));
    if (checkout_res->exitcode != 0) {
        die("failed to checkout " + latest_tag);
    }

    info("updated pmp v" + current_clean + " → v" + latest_clean);
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
        case "update":    cmd_update(args, ctx); break;
        case "rollback":  cmd_rollback(ctx); break;
        case "changelog": cmd_changelog(args, ctx); break;
        case "lock":      cmd_lock(ctx); break;
        case "store":     cmd_store(args, ctx); break;
        case "list":      cmd_list(args, ctx); break;
        case "clean":     cmd_clean(ctx); break;
        case "remove":    cmd_remove(args, ctx); break;
        case "run":       cmd_run(args, ctx); break;
        case "resolve":   cmd_resolve(args, ctx); break;
        case "env":       cmd_env(ctx); break;
        case "version":    cmd_version(); break;
        case "self-update": cmd_self_update(ctx); break;
        default:
            die("unknown command '" + cmd + "' (try: pmp --help)");
    }
    return 0;
}

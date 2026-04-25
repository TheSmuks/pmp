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
    write("  pmp install --frozen-lockfile               "
          "CI: fail if lockfile is missing or stale\n");
    write("  pmp install --offline                       "
          "Install from store only (no network)\n");
    write("  pmp add <url>                               "
          "Alias for pmp install <url>\n");
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
    write("  pmp store prune [--force]                   "
          "Remove unused store entries\n");
    write("  pmp list [-g]                               "
          "Show installed dependencies\n");
    write("  pmp env                                     "
          "Create .pike-env/ virtual environment\n");
    write("  pmp clean                                   "
          "Remove ./modules/ (keeps store)\n");
    write("  pmp remove <name>                           "
          "Remove a dependency\n");
    write("  pmp run <script>                            "
          "Run script with module paths\n");
    write("  pmp outdated                                "
          "Show deps with newer versions available\n");
    write("  pmp resolve [module]                        "
          "Print resolved module paths\n");
    write("  pmp version                                 "
          "Show version\n");
    write("  pmp self-update                             "
          "Update pmp to the latest version\n");
    write("  pmp verify                                 "
          "Verify installed dependencies\n");
    write("  pmp doctor                                 "
          "Diagnose common project issues\n");
    write("\nSource formats:\n");
    write("  github.com/owner/repo                       "
          "GitHub\n");
    write("  gitlab.com/owner/repo                       "
          "GitLab\n");
    write("  git.example.com/owner/repo                  "
          "Self-hosted git\n");
    write("  ./local/path or /abs/path                   "
          "Local module\n");
    write("\nOptions:\n");
    write("  --verbose         Enable debug output\n");
    write("  --quiet           Suppress informational output\n");
    write("\nExit codes:\n");
    write("  0  Success\n");
    write("  1  User error (invalid input, missing deps, network failure)\n");
    write("  2  Internal error (store corruption, hash mismatch)\n");
    write("\nEnvironment variables:\n");
    write("  GITHUB_TOKEN      GitHub API authentication\n");
    write("  PIKE_BIN          Override Pike binary path\n");
    write("  TMPDIR            Temp directory (default /tmp)\n");
    write("  PMP_VERBOSE       Set to 1 for debug output\n");
    write("  PMP_QUIET         Set to 1 to suppress output\n");
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
    mapping cur_v = parse_semver(current);
    mapping lat_v = parse_semver(latest_tag);


    if (!lat_v) {
        warn("latest tag is not a valid semver: " + latest_tag);
        info("pmp is up to date");
        return;
    }
    if (cur_v && lat_v && compare_semver(cur_v, lat_v) >= 0) {
        string cur_clean = has_prefix(current, "v") ? current[1..] : current;
        info("pmp is up to date (v" + cur_clean + ")");
        return;
    }

    // Checkout the latest tag
    mapping checkout_res = Process.run(({"git", "checkout", latest_tag}), (["cwd": pmp_dir]));
    if (checkout_res->exitcode != 0) {
        die("failed to checkout " + latest_tag);
    }

    info("updated pmp " + current + " → " + latest_tag);
}

int main(int argc, array(string) argv) {
    // Register signal handlers for cleanup on interrupt
    void cleanup_handler(int signum) {
        run_cleanup();
        werror("pmp: interrupted\n");
        exit(128 + signum);
    };
    signal(signum("SIGINT"), cleanup_handler);
    signal(signum("SIGTERM"), cleanup_handler);

    mixed err = catch {
        _main(argv);
    };
    if (err) {
        run_cleanup();
        werror("pmp: internal error: %s\n", describe_error(err));
        return EXIT_INTERNAL;
    }
    return EXIT_OK;
}

void _main(array(string) argv) {
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

    // Apply verbosity flags (override env vars)
    // Arg.parse only recognizes --flag before the command;
    // also check rest[] for flags placed after the command.
    if (opts->verbose || has_value(rest, "--verbose")) {
        set_verbose(1); set_quiet(0);
        rest -= ({"--verbose"});
    }
    if (opts->quiet || has_value(rest, "--quiet")) {
        set_quiet(1); set_verbose(0);
        rest -= ({"--quiet"});
    }

    if (opts->help) { print_help(); return 0; }
    if (opts->version) { cmd_version(); return 0; }
    if (sizeof(rest) == 0) { print_help(); return 0; }

    string cmd = rest[0];
    array(string) args = rest[1..];

    switch (cmd) {
        case "init":     cmd_init(ctx); break;
        case "install":  cmd_install(args, ctx); break;
        case "add":      cmd_install(args, ctx); break;  // alias for install <url>
        case "update":    cmd_update(args, ctx); break;
        case "rollback":  cmd_rollback(ctx); break;
        case "changelog": cmd_changelog(args, ctx); break;
        case "lock":      cmd_lock(ctx); break;
        case "store":     cmd_store(args, ctx); break;
        case "list":      cmd_list(args, ctx); break;
        case "clean":     cmd_clean(ctx); break;
        case "remove":    cmd_remove(args, ctx); break;
        case "run":       cmd_run(args, ctx); break;
        case "outdated":  cmd_outdated(ctx); break;
        case "resolve":   cmd_resolve(args, ctx); break;
        case "env":       cmd_env(ctx); break;
        case "version":    cmd_version(); break;
        case "self-update": cmd_self_update(ctx); break;
        case "verify":   if (!cmd_verify(ctx)) exit(EXIT_ERROR); break;
        case "doctor":   if (!cmd_doctor(ctx)) exit(EXIT_ERROR); break;
        default:
            die("unknown command '" + cmd + "' (try: pmp --help)");
    }
}

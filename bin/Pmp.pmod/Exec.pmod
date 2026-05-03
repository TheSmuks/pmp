// Exec.pmod — pmpx: download and execute a Pike module without installing.
// Fetches a remote module to the content-addressable store, creates a temp
// module directory with a symlink, and replaces the current process with
// the module's entry point script. No project files are modified.

import .Config;
import .Helpers;
import .Source;
import .Resolve;
import .Store;

//! Find the executable entry point in a store entry directory.
//! Checks pike.json "bin" field first, then common heuristic filenames,
//! then falls back to a single .pike file at the entry root.
//! Returns the absolute path to the script, or "" if none found.
string _find_entry_point(string entry_dir) {
    // 1. Check pike.json "bin" field
    string pike_json = combine_path(entry_dir, "pike.json");
    if (Stdio.exist(pike_json)) {
        string bin = json_field("bin", pike_json);
        if (bin && sizeof(bin) > 0) {
            string script = combine_path(entry_dir, bin);
            if (Stdio.is_file(script))
                return script;
            warn("pmpx: pike.json 'bin' field points to non-existent file: " + bin);
        }
    }

    // 2. Common heuristic filenames in priority order
    foreach (({"main.pike", "cli.pike", "cmd.pike"}); ; string candidate) {
        string path = combine_path(entry_dir, candidate);
        if (Stdio.is_file(path))
            return path;
    }

    // 3. Single .pike file at entry root (unambiguous)
    array(string) pike_files = filter(
        get_dir(entry_dir) || ({}),
        lambda(string f) {
            return has_suffix(f, ".pike")
                && Stdio.is_file(combine_path(entry_dir, f));
        }
    );
    if (sizeof(pike_files) == 1)
        return combine_path(entry_dir, pike_files[0]);

    return "";
}

//! Main pmpx command: download and execute a remote Pike module.
//! Parses <source>[@#version] [-- child_args...], resolves the version,
//! downloads to store (or reuses cached entry), finds the entry point,
//! builds PIKE_MODULE_PATH, and replaces the current process.
void cmd_pmpx(array(string) args, mapping ctx) {
    if (sizeof(args) == 0)
        die("pmpx: missing source specifier (try: pmp pmpx github.com/owner/repo)");

    // Split at "--" separator: everything before is pmpx args, after is child args
    int sep = search(args, "--");
    array(string) source_args;
    array(string) child_args;
    if (sep >= 0) {
        source_args = args[..sep - 1];
        child_args = args[sep + 1..];
    } else {
        source_args = args;
        child_args = ({});
    }

    if (sizeof(source_args) == 0)
        die("pmpx: missing source specifier before --");

    string source = source_args[0];

    // Parse source components
    string name = source_to_name(source);
    string version = source_to_version(source);
    string type = detect_source_type(source);

    // Local paths are not supported in pmpx — use pmp install instead
    if (type == "local")
        die("pmpx: local paths are not supported — use 'pmp install ./path' instead");

    string domain = source_to_domain(source);
    string repo_path = source_to_repo_path(source);
    if (sizeof(repo_path) == 0)
        die("pmpx: could not extract repo path from: " + source);

    // Resolve version if not pinned
    if (version == "") {
        if (ctx["offline"])
            die("pmpx: offline mode — pin a version (e.g. github.com/owner/repo#v1.0.0)");
        array(string) resolved =
            latest_tag(type, domain, repo_path, PMP_VERSION);
        if (sizeof(resolved[0]) == 0)
            die("pmpx: no tags found for " + repo_path);
        version = resolved[0];
    }

    // Download to store (store_install_* reuses existing entries automatically)
    mapping result;
    switch (type) {
        case "github":
            result = store_install_github(
                ctx["store_dir"], repo_path, version, PMP_VERSION);
            break;
        case "gitlab":
            result = store_install_gitlab(
                ctx["store_dir"], repo_path, version, PMP_VERSION);
            break;
        case "selfhosted":
            result = store_install_selfhosted(
                ctx["store_dir"], domain, repo_path, version, PMP_VERSION);
            break;
        default:
            die("pmpx: unsupported source type: " + type);
    }
    if (!result || !sizeof(result->entry))
        die("pmpx: store install failed for " + repo_path + " " + version, EXIT_INTERNAL);

    // Find executable entry point in the store entry
    string entry_dir = combine_path(ctx["store_dir"], result->entry);
    if (!Stdio.is_dir(entry_dir))
        die("pmpx: store entry missing: " + result->entry, EXIT_INTERNAL);
    string script = _find_entry_point(entry_dir);
    if (script == "")
        die("pmpx: no executable entry point found in " + result->entry
            + "\n  Add a 'bin' field to pike.json (e.g. {\"bin\": \"cli.pike\"})"
            + "\n  or provide one of: main.pike, cli.pike, cmd.pike");

    // Create temp module directory with symlink to store entry
    // so Pike can resolve imports from the executed module
    string tmpdir = make_temp_dir();
    string tmp_modules = combine_path(tmpdir, "modules");
    Stdio.mkdirhier(tmp_modules);

    mapping rmp = resolve_module_path(name, entry_dir,
        combine_path(entry_dir, "pike.json"));
    string link_path = combine_path(tmp_modules, rmp->link_name);
    symlink(rmp->target, link_path);

    // Build PIKE_MODULE_PATH: temp modules + project modules + global modules
    array(string) paths = ({ tmp_modules });
    string project_modules = combine_path(getcwd(), "modules");
    if (Stdio.is_dir(project_modules))
        paths += ({ project_modules });
    if (Stdio.is_dir(ctx["global_dir"]))
        paths += ({ ctx["global_dir"] });

    putenv("PIKE_MODULE_PATH", paths * ":");

    // Replace current process — exec never returns on success
    info("running " + name + " " + version);
    Process.exec(ctx["pike_bin"], script, @child_args);
    die("pmpx: failed to exec " + script);
}

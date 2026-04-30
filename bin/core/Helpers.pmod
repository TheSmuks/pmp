//! Strip UTF-8 BOM from raw file content if present.
string _strip_bom(string raw) {
    if (sizeof(raw) >= 3 && has_prefix(raw, "\xef\xbb\xbf"))
        return raw[3..];
    return raw;
}

inherit Config;
protected Regexp RE_DASHES = Regexp("-+");

//! Cleanup registry for signal handling and error recovery.
//! Uses getenv/putenv for shared state across module inheritance copies.

// Cleanup dirs: RS-separated list of temp directories to clean up on exit.
// Uses ASCII Record Separator (0x1E) as delimiter — safe for paths and putenv.
private array(string) _get_cleanup_dirs() {
    string v = getenv("PMP_CLEANUP_DIRS") || "";
    if (sizeof(v) == 0) return ({});
    return v / "\x1e";
}
private void _set_cleanup_dirs(array(string) dirs) {
    putenv("PMP_CLEANUP_DIRS", dirs * "\x1e");
}

//! Register a temp directory for cleanup on exit/signal.
void register_cleanup_dir(string dir) {
    array(string) dirs = _get_cleanup_dirs();
    if (sizeof(dir) > 0 && !has_value(dirs, dir)) {
        dirs += ({ dir });
        _set_cleanup_dirs(dirs);
    }
}

//! Unregister a temp directory (after successful cleanup).
void unregister_cleanup_dir(string dir) {
    array(string) dirs = _get_cleanup_dirs();
    dirs -= ({ dir });
    _set_cleanup_dirs(dirs);
}

// Project lock path: for cleanup on die().
private string _get_registered_project_lock() {
    return getenv("PMP_PROJECT_LOCK") || "";
}
//! Register the project lock path for cleanup on die().
void register_project_lock_path(string lock_path) {
    putenv("PMP_PROJECT_LOCK", lock_path);
}

// Store lock state: whether store lock is held and which directory.
private int _get_store_locked() { return (int)(getenv("PMP_STORE_LOCKED") || "0"); }
private string _get_store_dir_for_lock() { return getenv("PMP_STORE_DIR_LOCK") || ""; }
void set_store_lock_state(int locked, string dir) {
    putenv("PMP_STORE_LOCKED", (string)locked);
    putenv("PMP_STORE_DIR_LOCK", dir || "");
}

// Cleanup guard: prevent double-invocation.
private int _get_cleaned_up() { return (int)(getenv("PMP_CLEANED_UP") || "0"); }
private void _set_cleaned_up() { putenv("PMP_CLEANED_UP", "1"); }


//! Run all registered cleanup actions. Called on signal and normal exit.
//! Guarded against double-invocation (e.g. signal during cleanup).
void run_cleanup() {
    if (_get_cleaned_up()) return;
    _set_cleaned_up();
    // Clean up temp dirs
    array(string) dirs = _get_cleanup_dirs();
    foreach (dirs; ; string d) {
        if (Stdio.is_dir(d)) {
            Stdio.recursive_rm(d);
        }
    }
    _set_cleanup_dirs(({}));

    // Release store lock
    if (_get_store_locked() && sizeof(_get_store_dir_for_lock()) > 0) {
        string store_dir = _get_store_dir_for_lock();
        string lock_path = combine_path(store_dir, ".lock");
        advisory_unlock(lock_path);
        set_store_lock_state(0, "");
    }

    // Release project lock
    string proj_lock = _get_registered_project_lock();
    if (sizeof(proj_lock) > 0) {
        advisory_unlock(proj_lock);
        register_project_lock_path("");
    }
}

//! Advisory lock primitives for file-based locking.
//! Uses PID-based lock files with stale-lock detection.

void advisory_lock(string lock_path, string description) {
    string my_pid = (string)getpid();

    for (int attempt = 0; attempt < 2; attempt++) {
        mixed err = catch {
            Stdio.File lf = Stdio.File(lock_path, "wxc");
            lf->write(my_pid);
            lf->close();
        };
        if (!err) return;

        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (sizeof(existing) > 0) {
            int pid = (int)existing;
            if (pid > 0) {
                mapping r = Process.run(({"kill", "-0", (string)pid}));
                if (r->exitcode == 0)
                    die(description + " is locked by pmp process " + pid
                        + " — remove " + lock_path + " manually");
                // EPERM — process exists but we lack permission to signal it
                string err = lower_case(r->stderr || "");
                if (has_value(err, "not permitted"))
                    die(description + " is locked by process " + pid
                        + " (no signal permission) — remove " + lock_path + " manually");
                // ESRCH — process doesn't exist, stale lock
                info("removing stale " + description + " lock from process " + pid);
                rm(lock_path);
                continue;
            }
        }
        rm(lock_path);
    }
    die("failed to acquire " + description + " lock after retry");
}

void advisory_unlock(string lock_path) {
    if (Stdio.exist(lock_path)) {
        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (existing == (string)getpid())
            rm(lock_path);
    }
}

// ── Project-level lock ───────────────────────────────────────────────

private string _project_lock_path(string project_root) {
    return combine_path(project_root || getcwd(), ".pmp-install.lock");
}

//! Acquire a project-level advisory lock. Removes stale locks held by dead processes.
void project_lock(void|string project_root) {
    string lock_path = _project_lock_path(project_root);
    advisory_lock(lock_path, "project");
    register_project_lock_path(lock_path);
}

//! Release the project-level lock.
void project_unlock(void|string project_root) {
    string lock_path = _project_lock_path(project_root);
    advisory_unlock(lock_path);
    register_project_lock_path("");
}

// ── Store-level lock ──────────────────────────────────────────────────

//! Acquire an advisory lock on the store directory.
//! Uses a PID-based lock file. Dies if another pmp process holds the lock.
//! Call store_unlock() when done.
void store_lock(string store_dir) {
    Stdio.mkdirhier(store_dir);
    string lock_path = combine_path(store_dir, ".lock");
    advisory_lock(lock_path, "store");
    set_store_lock_state(1, store_dir);
}

//! Release the store lock.
void store_unlock(string store_dir) {
    string lock_path = combine_path(store_dir, ".lock");
    advisory_unlock(lock_path);
    set_store_lock_state(0, "");
}

//! Utility helpers: logging, command checks, JSON reading, SHA-256.

void die(string msg, void|int code) {
    werror("pmp: %s\n", msg);
    run_cleanup();
    exit(code || EXIT_ERROR);
}

void info(string msg) {
    if (!_quiet())
        write("pmp: %s\n", msg);
}

void warn(string msg) {
    werror("pmp: warning: %s\n", msg);
}

//! Strip credentials from a URL for safe display in error messages.
//! Replaces user:pass@ or token@ with ***@
string sanitize_url(string url) {
    // Match scheme://credentials@host/path
    if (sscanf(url, "%s://%s@%s", string scheme, string creds, string rest) == 3) {
        return scheme + "://***@" + rest;
    }
    return url;
}

//! Debug message — only printed when PMP_VERBOSE is set.
void debug(string msg) {
    if (_verbose())
        write("pmp: debug: %s\n", msg);
}

void die_internal(string msg) {
    werror("pmp: internal error: %s\n", msg);
    run_cleanup();
    exit(EXIT_INTERNAL);
}

void need_cmd(string name) {
    if (!Process.search_path(name))
        die("requires " + name);
}

//! Read and parse a JSON file, returning a mapping.
//! Handles UTF-8 BOM, validates the result is a mapping.
//! Returns 0 (void) if the file doesn't exist, is empty, or is valid JSON but not a mapping.
//! Dies with an error for malformed JSON.
mapping|void _read_json_mapping(string file) {
    string raw = Stdio.read_file(file);
    if (!raw) return 0;  // File doesn't exist
    raw = _strip_bom(raw);
    if (sizeof(raw) == 0) return 0;  // Empty file
    mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err) die(file + ": invalid JSON");
    if (!mappingp(data)) return 0;  // Valid JSON but not a mapping
    return data;
}

//! Read a field from a JSON file using proper JSON parsing.
//! @param field
//!   The top-level key to look up.
//! @param file
//!   Path to the JSON file (required — no global fallback).
void|mixed json_field(string field, string file) {
    mapping data = _read_json_mapping(file);
    if (!data) return 0;
    if (!zero_type(data[field])) return data[field];
    return 0;
}

//! Walk up from directory to find pike.json.
void|string find_project_root(void|string dir) {
    string d = dir || getcwd();
    while (d != "/") {
        if (Stdio.exist(combine_path(d, "pike.json")))
            return d;
        string parent = combine_path(d, "..");
        if (parent == d) break;
        d = parent;
    }
    return 0;
}

//! Compute SHA-256 hex digest of a file.
//! Dies on failure — hash computation failure is not recoverable.
string compute_sha256(string path) {
    object f = Stdio.File(path, "r");
    if (!f) die_internal("failed to open file for hashing: " + path);
    string hash = Crypto.SHA256.hash(f);
    f->close();
    return String.string2hex(hash);
}

//! Normalize a source string into a slug for use in store entry names.
//! Converts / to -, collapses repeated dashes, trims leading/trailing dashes.
string normalize_slug(string s) {
    string slug = normalize_tag(s);
    while (has_prefix(slug, "-")) slug = slug[1..];
    while (has_suffix(slug, "-")) slug = slug[..<1];
    return slug;
}

//! Sanitize a tag for use in store entry names.
//! Converts / to - and collapses repeated dashes.
string normalize_tag(string tag) {
    string safe = replace(tag, "/", "-");
    safe = RE_DASHES->replace(safe, "-");
    return safe;
}

//! Create a temp directory using mktemp and register it for cleanup.
//! Dies if directory creation fails.
string make_temp_dir() {
    string tmpdir_base = combine_path(getenv("TMPDIR") || "/tmp", "pmp_install_XXXXXX");
    mapping mktemp_result = Process.run(({"mktemp", "-d", tmpdir_base}));
    string tmpdir = String.trim_all_whites(mktemp_result->stdout || "");
    if (sizeof(tmpdir) == 0) die("failed to create temp directory");
    register_cleanup_dir(tmpdir);
    return tmpdir;
}

//! Resolve a potentially relative local path to absolute.
//! Prepends project root if path starts with ./
string resolve_local_path(string path) {
    if (has_prefix(path, "./")) {
        string project_root = find_project_root() || getcwd();
        return combine_path(project_root, path);
    }
    return path;
}

//! Strip .pmod suffix from a module name for display purposes.
string display_name(string name) {
    if (has_suffix(name, ".pmod"))
        return name[..<5];
    return name;
}

//! Check if path is a symbolic link. Portable wrapper.
//! Uses Stdio.is_link which uses lstat internally.
int(0..1) is_symlink(string path) {
    return Stdio.is_link(path);
}

//! Read the target of a symbolic link.
//! Returns 0 if path is not a symlink or does not exist.
mixed get_symlink_target(string path) {
    if (!Stdio.is_link(path)) return 0;
    string target = 0;
    catch { target = readlink(path); };
    return target;
}

//! Snapshot all symlink targets in a directory.
//! Returns mapping from link name → target path.
mapping(string:string) snapshot_symlinks(string dir) {
    mapping(string:string) snaps = ([]);
    foreach (get_dir(dir) || ({}); ; string name) {
        string link = combine_path(dir, name);
        string target = get_symlink_target(link);
        if (target) snaps[name] = target;
    }
    return snaps;
}

//! Generate a unique temp file suffix using pid, timestamp, and random bytes.
private string _temp_suffix() {
    return ".tmp." + getpid() + "." + time() + "."
        + String.string2hex(Crypto.Random.random_string(8));
}

//! Atomically create or replace a symlink at dest pointing to target.
void atomic_symlink(string target, string dest) {
    // If dest is a directory (not a symlink), remove it before installing.
    // This handles upgrades from bare directories to proper symlinks.
    if (Stdio.is_dir(dest) && !is_symlink(dest)) {
        // Not a symlink — it's a real directory. Remove it.
        Stdio.recursive_rm(dest);
    }
    // Use Crypto.Random for strong uniqueness: pid + timestamp + 64-bit random
    string tmp_link = dest + _temp_suffix();
    // Clean up any leftover temp link from a previous crash
    rm(tmp_link);
    mixed link_err = catch { symlink(target, tmp_link); };
    if (link_err)
        die("failed to create symlink: " + tmp_link + " (" + describe_error(link_err) + ")", EXIT_INTERNAL);
    if (!mv(tmp_link, dest)) {
        rm(tmp_link);
        die("failed to install symlink: " + dest, EXIT_INTERNAL);
    }
}

//! Atomically write content to a file.
//! Uses write-to-temp + rename(2) to prevent truncation on crash.
//! Dies on failure (EXIT_INTERNAL).
void atomic_write(string path, string content) {
    string tmp_path = path + _temp_suffix();
    int bytes = Stdio.write_file(tmp_path, content);
    if (bytes != sizeof(content)) {
        rm(tmp_path);
        die("failed to write file atomically (disk full?): " + path, EXIT_INTERNAL);
    }
    if (!mv(tmp_path, path)) {
        // Cross-filesystem mv failed — clean up and die
        rm(tmp_path);
        die("failed to write file atomically (cross-filesystem?): " + path, EXIT_INTERNAL);
    }
}

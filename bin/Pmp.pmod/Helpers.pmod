inherit .Config;

//! Cleanup registry for signal handling and error recovery.
//! Tracks temp dirs and store lock for cleanup on exit/interrupt.
private array(string) _cleanup_dirs = ({});
private string _store_dir_for_lock = "";
private int _store_locked = 0;

//! Register a temp directory for cleanup on exit/signal.
void register_cleanup_dir(string dir) {
    if (sizeof(dir) > 0 && search(_cleanup_dirs, dir) < 0)
        _cleanup_dirs += ({ dir });
}

//! Unregister a temp directory (after successful cleanup).
void unregister_cleanup_dir(string dir) {
    _cleanup_dirs -= ({ dir });
}

//! Register store lock state for cleanup.
void register_store_lock(string store_dir) {
    _store_dir_for_lock = store_dir;
    _store_locked = 1;
}

//! Clear store lock state (after successful unlock).
void clear_store_lock() {
    _store_locked = 0;
}

//! Run all registered cleanup actions. Called on signal and normal exit.
void run_cleanup() {
    // Clean up temp dirs
    foreach (_cleanup_dirs; ; string d) {
        if (Stdio.is_dir(d)) {
            Stdio.recursive_rm(d);
        }
    }
    _cleanup_dirs = ({});

    // Release store lock
    if (_store_locked && sizeof(_store_dir_for_lock) > 0) {
        string lock_path = combine_path(_store_dir_for_lock, ".lock");
        if (Stdio.exist(lock_path)) {
            string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
            if (existing == (string)getpid())
                rm(lock_path);
        }
        _store_locked = 0;
    }
}

//! Utility helpers: logging, command checks, JSON reading, SHA-256.

void die(string msg, void|int code) {
    werror("pmp: %s\n", msg);
    exit(code || EXIT_ERROR);
}

void info(string msg) {
    if (!PMP_QUIET)
        write("pmp: %s\n", msg);
}

void warn(string msg) {
    werror("pmp: warning: %s\n", msg);
}

//! Debug message — only printed when PMP_VERBOSE is set.
void debug(string msg) {
    if (PMP_VERBOSE)
        write("pmp: debug: %s\n", msg);
}

void die_internal(string msg) {
    werror("pmp: internal error: %s\n", msg);
    exit(EXIT_INTERNAL);
}

void need_cmd(string name) {
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    if (!Process.locate_binary(search_path, name))
        die("requires " + name);
}

//! Read a field from a JSON file using proper JSON parsing.
//! @param field
//!   The top-level key to look up.
//! @param file
//!   Path to the JSON file (required — no global fallback).
void|string json_field(string field, string file) {
    if (!Stdio.exist(file)) return 0;
    string raw = Stdio.read_file(file);
    if (!raw) return 0;
    mapping|mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) return 0;
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
//! Uses streaming reads (64KB chunks) to avoid loading entire file into memory.
//! Dies on failure — hash computation failure is not recoverable.
string compute_sha256(string path) {
    object f = Stdio.File(path, "r");
    if (!f) die_internal("failed to open file for hashing: " + path);
    Crypto.SHA256 sha = Crypto.SHA256();
    while (1) {
        string chunk = f->read(65536);
        if (!chunk || sizeof(chunk) == 0) break;
        sha->update(chunk);
    }
    f->close();
    return String.string2hex(sha->digest());
}

//! Strip .pmod suffix from a module name for display purposes.
string display_name(string name) {
    if (has_suffix(name, ".pmod"))
        return name[..<5];
    return name;
}

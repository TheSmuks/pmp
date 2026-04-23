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
private int _cleaned_up = 0;


//! Run all registered cleanup actions. Called on signal and normal exit.
//! Guarded against double-invocation (e.g. signal during cleanup).
void run_cleanup() {
    if (_cleaned_up) return;
    _cleaned_up = 1;
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
    mixed err = catch {
        while (1) {
            string chunk = f->read(65536);
            if (!chunk || sizeof(chunk) == 0) break;
            sha->update(chunk);
        }
    };
    f->close();
    if (err) throw(err);
    return String.string2hex(sha->digest());
}

//! Strip .pmod suffix from a module name for display purposes.
string display_name(string name) {
    if (has_suffix(name, ".pmod"))
        return name[..<5];
    return name;
}


//! Atomically create or replace a symlink at dest pointing to target.
//! Uses temp symlink + rename(2) so there is no window where dest is missing.
//! rename(2) on POSIX atomically replaces the target path.
void atomic_symlink(string target, string dest) {
    // If dest is a directory (not a symlink), remove it before installing.
    // This handles upgrades from bare directories to proper symlinks.
    if (Stdio.is_dir(dest)) {
        mixed readlink_err = catch(System.readlink(dest));
        if (readlink_err)
            // Not a symlink — it's a real directory. Remove it.
            Stdio.recursive_rm(dest);
    }
    // Use Crypto.Random for strong uniqueness: pid + timestamp + 64-bit random
    string tmp_link = dest + ".tmp." + getpid() + "." + time() + "."
        + String.string2hex(Crypto.Random.random_string(8));
    // Clean up any leftover temp link from a previous crash
    rm(tmp_link);
    mixed link_err = catch { System.symlink(target, tmp_link); };
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
    string tmp_path = path + ".tmp." + getpid() + "." + time() + "." + random(100000);
    Stdio.write_file(tmp_path, content);
    if (!mv(tmp_path, path)) {
        // mv may fail across filesystems — try harder
        warn("atomic_write: rename failed, attempting copy");
        mixed cp_err = catch {
            Stdio.write_file(path, Stdio.read_file(tmp_path));
            rm(tmp_path);
        };
        if (cp_err) {
            rm(tmp_path);
            die("failed to write file atomically: " + path, EXIT_INTERNAL);
        }
    }
}

//! Utility helpers: logging, command checks, JSON reading, SHA-256.

void die(string msg) {
    werror("pmp: %s\n", msg);
    exit(1);
}

void info(string msg) {
    write("pmp: %s\n", msg);
}

void warn(string msg) {
    werror("pmp: warning: %s\n", msg);
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
string compute_sha256(string path) {
    string data = Stdio.read_file(path);
    if (!data) return "unknown";
    return String.string2hex(Crypto.SHA256.hash(data));
}

//! Strip .pmod suffix from a module name for display purposes.
string display_name(string name) {
    if (has_suffix(name, ".pmod"))
        return name[..<5];
    return name;
}

inherit Helpers;

constant LOCKFILE_VERSION = 1;

//! Add an entry to a lockfile entries array.
//! Returns a new array (Pike arrays are reference types; += creates a new array).
array(array(string)) lockfile_add_entry(array(array(string)) entries,
                                        string name, string source,
                                        string tag, string sha,
                                        string hash) {
    return entries + ({ ({ name, source, tag, sha, hash }) });
}
//! Merge new lockfile entries into existing, deduplicating by name.
//! New entries replace existing ones with the same name.
array(array(string)) merge_lock_entries(array(array(string)) existing,
                                              array(array(string)) new_entries) {
    mapping(string:array(string)) by_name = ([]);
    // Walk existing first
    foreach (existing; ; array(string) e)
        if (sizeof(e[0]))
            by_name[e[0]] = e;
    // Walk new — last wins for same name, overrides existing
    foreach (new_entries; ; array(string) e)
        if (sizeof(e[0]))
            by_name[e[0]] = e;
    // Return sorted by name for deterministic output
    array(string) names = sort(indices(by_name));
    return rows(by_name, names);
}
//! Write lockfile entries to disk.
//! Validates that no field contains tab characters (would corrupt the format).
void write_lockfile(string lockfile_path, array(array(string)) entries) {
    // Validate entries — no field may contain a tab
    foreach (entries; ; array(string) entry) {
        if (sizeof(entry) < 5)
            die("lockfile entry has fewer than 5 fields: " + sizeof(entry) + " fields", EXIT_INTERNAL);
        foreach (entry; int i; string field) {
            if (has_value(field, "\0"))
                die("lockfile field contains null byte: " + field[..20], EXIT_INTERNAL);
            if (has_value(field, "\t"))
                die("lockfile field contains tab character: " + field, EXIT_INTERNAL);
            if (has_value(field, "\n"))
                die("lockfile field contains newline: " + field, EXIT_INTERNAL);
        }
    }

    // Backup existing lockfile before overwriting
    if (Stdio.exist(lockfile_path)) {
        string existing = Stdio.read_file(lockfile_path);
        if (existing != 0)
            atomic_write(lockfile_path + ".prev", existing);
    }

    String.Buffer buf = String.Buffer();
    buf->add("# pmp lockfile v" + LOCKFILE_VERSION + " — DO NOT EDIT\n");
    buf->add("# name\tsource\ttag\tcommit_sha\tcontent_sha256\n");
    foreach (entries; ; array(string) entry) {
        if (sizeof(entry) < 5) continue;
        buf->add(entry[..4] * "\t" + "\n");
    }
    // Atomic write: write to tmp file, then rename via mv() (wraps rename(2))
    atomic_write(lockfile_path, buf->get());
}
//! Read lockfile entries. Returns array of ({name, source, tag, sha, hash}).
array(array(string)) read_lockfile(void|string lf) {
    string path = lf || "pike.lock";
    if (!Stdio.exist(path)) return ({});

    string raw = Stdio.read_file(path);
    if (!raw || sizeof(raw) == 0) return ({});

    array(string) lines;
    // Strip carriage returns before processing
    lines = replace(raw, "\r", "") / "\n";

    // Check lockfile format version
    int found_version = 0;
    foreach (lines; ; string line) {
        if (sscanf(line, "# pmp lockfile v%d", int v) == 1) {
            if (v > LOCKFILE_VERSION)
                die("lockfile format v" + v + " is newer than supported (v"
                    + LOCKFILE_VERSION + ") — update pmp");
            found_version = 1;
            break;
        }
    }
    if (!found_version)
        warn("lockfile has no version header — format may be unrecognized");

    array(array(string)) entries = ({});
    foreach (lines; ; string line) {
        if (has_prefix(line, "#") || sizeof(line) == 0) continue;
        array parts = line / "\t";
        if (sizeof(parts) >= 5 && sizeof(parts[0]) > 0) {
            string name = parts[0];
            if (has_value(name, "/")
                || has_value(name, "\0")) {
                warn("lockfile entry has invalid name field: " + name[..60]);
                continue;
            }
            if (name == ".") {
                warn("lockfile entry with invalid name '.' — skipping");
                continue;
            }
            // Validate source field — prevent path traversal in local deps
            string src = parts[1];
            if (has_prefix(src, "./") || has_prefix(src, "/")) {
                if (has_value(src, ".."))
                    die("lockfile: path traversal in local dep source: " + src, EXIT_INTERNAL);
            }
            entries += ({ parts[..4] });
        }
    }
    return entries;
}

//! Check if a dependency exists in the lockfile, optionally verifying source.
//! When source is provided, both name and source must match.
int lockfile_has_dep(string name, void|string lf, void|string source,
                        void|array(array(string)) entries) {
    if (!entries) entries = read_lockfile(lf);
    return Array.any(entries, lambda(array(string) entry) {
        if (entry[0] != name) return 0;
        if (!source) return 1;
        return entry[1] == source;
    });
}
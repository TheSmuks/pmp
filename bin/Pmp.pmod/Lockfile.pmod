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
    multiset(string) seen = (<>);
    // Walk new entries first — they take priority
    array(array(string)) result = new_entries + ({});
    foreach (new_entries; ; array(string) e)
        seen[e[0]] = 1;
    // Keep existing entries whose names are not overridden
    foreach (existing; ; array(string) e)
        if (!seen[e[0]])
            result += ({ e });
    return result;
}

//! Write lockfile entries to disk.
void write_lockfile(string lockfile_path, array(array(string)) entries) {
    // Backup existing lockfile before overwriting
    if (Stdio.exist(lockfile_path)) {
        string existing = Stdio.read_file(lockfile_path);
        if (existing && sizeof(existing) > 0)
            Stdio.write_file(lockfile_path + ".prev", existing);
    }

    String.Buffer buf = String.Buffer();
    buf->add("# pmp lockfile v1 — DO NOT EDIT\n");
    buf->add("# name\tsource\ttag\tcommit_sha\tcontent_sha256\n");
    foreach (entries; ; array(string) entry) {
        buf->add(entry[0] + "\t" + entry[1] + "\t" + entry[2]
                 + "\t" + entry[3] + "\t" + entry[4] + "\n");
    }
    // Atomic write: write to tmp file, then rename
    string tmp_path = lockfile_path + ".tmp";
    Stdio.write_file(tmp_path, buf->get());
    mapping r = Process.run(({"mv", tmp_path, lockfile_path}));
    if (r->exitcode != 0) {
        werror("pmp: failed to write lockfile: " + (r->stderr || "unknown error") + "\n");
        exit(1);
    }
}
//! Read lockfile entries. Returns array of ({name, source, tag, sha, hash}).
array(array(string)) read_lockfile(void|string lf) {
    string path = lf || "pike.lock";
    if (!Stdio.exist(path)) return ({});

    string raw = Stdio.read_file(path);
    array(array(string)) entries = ({});
    foreach (raw / "\n"; ; string line) {
        if (has_prefix(line, "#") || sizeof(line) == 0) continue;
        array parts = line / "\t";
        if (sizeof(parts) >= 5 && sizeof(parts[0]) > 0)
            entries += ({ parts[..4] });
    }
    return entries;
}

//! Check if a dependency exists in the lockfile, optionally verifying source.
//! When source is provided, both name and source must match.
int lockfile_has_dep(string name, void|string lf, void|string source) {
    foreach (read_lockfile(lf); ; array(string) entry)
        if (entry[0] == name)
            return source ? entry[1] == source : 1;
    return 0;
}
//! Add an entry to a lockfile entries array.
//! Returns a new array (Pike arrays are reference types; += creates a new array).
array(array(string)) lockfile_add_entry(array(array(string)) entries,
                                        string name, string source,
                                        string tag, string sha,
                                        string hash) {
    return entries + ({ ({ name, source, tag, sha, hash }) });
}

//! Write lockfile entries to disk.
void write_lockfile(string lockfile_path, array(array(string)) entries) {
    if (sizeof(entries) == 0) return;

    String.Buffer buf = String.Buffer();
    buf->add("# pmp lockfile v1 — DO NOT EDIT\n");
    buf->add("# name\tsource\ttag\tcommit_sha\tcontent_sha256\n");
    foreach (entries; ; array(string) entry) {
        buf->add(entry[0] + "\t" + entry[1] + "\t" + entry[2]
                 + "\t" + entry[3] + "\t" + entry[4] + "\n");
    }
    Stdio.write_file(lockfile_path, buf->get());
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

//! Check if a dependency name exists in the lockfile.
int lockfile_has_dep(string name, void|string lf) {
    foreach (read_lockfile(lf); ; array(string) entry)
        if (entry[0] == name) return 1;
    return 0;
}

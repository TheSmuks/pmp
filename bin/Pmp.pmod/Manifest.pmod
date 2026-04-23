inherit .Helpers;

//! Add a dependency to a pike.json manifest file.
//! @param pike_json
//!   Path to the pike.json file.
//! @param name
//!   Dependency name.
//! @param source
//!   Dependency source URL.
void add_to_manifest(string pike_json, string name, string source) {
    if (!Stdio.exist(pike_json)) {
        warn("pike.json not found: " + pike_json);
        return;
    }

    string raw = Stdio.read_file(pike_json);
    if (!raw) { warn("failed to read " + pike_json); return; }

    mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) {
        warn("failed to parse " + pike_json + ": " + describe_error(err));
        return;
    }

    // Check if already present in dependencies (not raw string search)
    // to avoid false positive when name appears in other fields
    if (mappingp(data->dependencies) &&
        !zero_type(data->dependencies[name])) return;

    if (!mappingp(data->dependencies))
        data->dependencies = ([]);
    data->dependencies[name] = source;

    string encoded = Standards.JSON.encode(data,
                                           Standards.JSON.HUMAN_READABLE);
    mixed write_err = catch { atomic_write(pike_json, encoded + "\n"); };
    if (write_err) die("failed to write " + pike_json);
}

//! Parse dependencies from a pike.json file.
//! @param file
//!   Path to the pike.json file. Required.
//! @returns
//!   Array of ({name, source}) pairs, sorted by name.
array(array(string)) parse_deps(string file) {
    if (!Stdio.exist(file)) return ({});

    string raw = Stdio.read_file(file);
    if (!raw) return ({});

    mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) return ({});

    mapping deps = data->dependencies;
    if (!mappingp(deps)) return ({});

    array(array(string)) result = ({});
    foreach (sort(indices(deps)); ; string name) {
        string val = deps[name];
        if (stringp(val) && sizeof(val) > 0)
            result += ({ ({ name, val }) });
    }
    return result;
}

import .Helpers;

//! Add a dependency to a pike.json manifest file.
//! @param pike_json
//!   Path to the pike.json file.
//! @param name
//!   Dependency name.
//! @param source
//!   Dependency source URL.
void add_to_manifest(string pike_json, string name, string source) {
    validate_dep_name(name);
    mapping data = _read_json_mapping(pike_json);
    if (!data) {
        warn("failed to read " + pike_json);
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
    // Read and validate JSON before _read_json_mapping, which dies on
    // malformed JSON. parse_deps is a query function — it returns empty, not die.
    string raw = Stdio.read_file(file);
    if (!raw) return ({});
    raw = _strip_bom(raw);
    mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) return ({});

    if (!mappingp(data->dependencies))
        return ({});

    mapping deps = data->dependencies;

    return map(filter(sort(indices(deps)), lambda(string name) {
        mixed val = deps[name];
        return stringp(val) && sizeof(val) > 0 && sizeof(name) > 0
            && !has_value(name, "/") && !has_value(name, "\\")
            && !has_value(name, "..") && !has_value(name, "\0");
    }), lambda(string name) {
        return ({ name, deps[name] });
    });
}
import .Helpers;
import .Manifest;
// Pre-compiled regexps for import/inherit/include scanning
public Regexp RE_IMPORT = Regexp("import[ \t]+([.A-Za-z_][A-Za-z0-9_.]*)");
public Regexp RE_INHERIT = Regexp("inherit[ \t]+([.A-Za-z_][A-Za-z0-9_.]*)");
public Regexp RE_INCLUDE_PMOD = Regexp("#include[ \t]*<([.A-Za-z_][A-Za-z0-9_.]*).pmod/");
public Regexp RE_IF_CONSTANT = Regexp("#if[ \t]+constant[ \t]*[(][ \t]*([A-Za-z_][A-Za-z0-9_]*)[)]");
public Regexp RE_IMPORT_STRING = Regexp("import[ \t]+\"([^\"]+)\"");


string strip_comments_and_strings(string content) {
    String.Buffer buf = String.Buffer();
    int i = 0;
    int len = sizeof(content);

    while (i < len) {
        // Single-line comment
        if (i + 1 < len && content[i..i] == "/" && content[i+1..i+1] == "/") {
            while (i < len && content[i..i] != "\n")
                i++;
            continue;
        }
        // Block comment — track nesting depth
        if (i + 1 < len && content[i..i] == "/" && content[i+1..i+1] == "*") {
            int depth = 1;
            i += 2;
            while (i + 1 < len && depth > 0) {
                if (content[i..i] == "/" && i + 1 < len && content[i+1..i+1] == "*") {
                    depth++;
                    i += 2;
                } else if (content[i..i] == "*" && i + 1 < len && content[i+1..i+1] == "/") {
                    depth--;
                    i += 2;
                } else {
                    i++;
                }
            }
            continue;
        }
        // String literal
        if (content[i..i] == "\"") {
            i++;
            while (i < len && content[i..i] != "\"") {
                if (content[i..i] == "\\" && i + 1 < len)
                    i++;
                i++;
            }
            if (i < len) i++;
            continue;
        }
        // Character literal
        if (content[i..i] == "'") {
            i++;
            while (i < len && content[i..i] != "'") {
                if (content[i..i] == "\\" && i + 1 < len)
                    i++;
                i++;
            }
            if (i < len) i++;
            continue;
        }
        buf->add(content[i..i]);
        i++;
    }

    return buf->get();
}

//! Build std_libs from the running Pike's module path.
multiset(string) init_std_libs(void|string pike_bin) {
    multiset(string) libs = (<>);
    string mp = getenv("PIKE_MODULE_PATH") || "";

    array(string) dirs = ({});
    if (sizeof(mp) > 0)
        dirs += mp / ":" - ({ "" });

    // Infer Pike home from the running binary
    if (pike_bin && sizeof(pike_bin) > 0) {
        array(string) parts = pike_bin / "/";
        if (sizeof(parts) > 2) {
            string pike_home = parts[..sizeof(parts)-3] * "/";
            dirs += ({ combine_path(pike_home, "lib/modules") });
        }
    }

    foreach (dirs; ; string dir) {
        if (!Stdio.is_dir(dir)) continue;
        foreach (get_dir(dir) || ({}); ; string entry) {
            string full = combine_path(dir, entry);
            if (has_suffix(entry, ".pmod")) {
                libs[entry[..<5]] = 1;
            } else if (has_suffix(entry, ".so")) {
                string name = entry[..<3];
                array(string) parts = name / "-";
                if (sizeof(parts) > 1 && sizeof(parts[-1]) > 0 &&
                    (< '0','1','2','3','4','5','6','7','8','9' >)[parts[-1][0]])
                    name = parts[..sizeof(parts)-2] * "-";
                libs[name] = 1;
            } else if (Stdio.is_dir(full)) {
                if (Stdio.exist(combine_path(full, "module.pmod")) ||
                    Stdio.exist(combine_path(full, "module.pike")))
                    libs[entry] = 1;
            }
        }
    }

    // Always include known builtins that may not appear as files
    libs |= (<
        "Stdio", "Array", "Mapping", "Multiset", "String", "System",
        "Thread", "__builtin", "Crypto", "Protocols", "ADT", "Cache",
        "Calendar", "Colors", "GL", "Graphics", "GTK", "Java", "Locale",
        "MIME", "Math", "Module", "Parser", "Pike", "Process", "SSL",
        "Web", "Regexp", "Sql", "Standards", "Filesystem", "Debug",
        "Error", "Concurrent", "Val", "Int", "Float", "Function",
        "Program", "Object", "Serializer", "Search", "Tools", "Git",
        "Image", "Yp"
    >);

    return libs;
}

void validate_manifests(string local_dir, multiset(string) std_libs,
                        void|string pike_json_override) {
    if (!Stdio.is_dir(local_dir)) return;
    info("validating imports against declared dependencies...");

    foreach (get_dir(local_dir) || ({}); ; string mod_name) {
        string moddir = combine_path(local_dir, mod_name);
        if (!Stdio.is_dir(moddir)) continue;

        // Resolve real path through symlink
        string real_dir = get_symlink_target(moddir) || moddir;

        // Collect imports/inherits/includes from .pike and .pmod files
        multiset(string) imports = (<>);

        // Recurse into all directories (not just .pmod-suffixed),
        // skip hidden dirs, limit depth
        void collect_imports(string dir, int depth) {
            if (!Stdio.is_dir(dir)) return;
            if (depth > 10) return;
            foreach (get_dir(dir) || ({}); ; string entry) {
                if (sizeof(entry) > 0 && entry[0] == '.') continue;
                string full = combine_path(dir, entry);
                if (Stdio.is_dir(full)) {
                    collect_imports(full, depth + 1);
                }
                if ((has_suffix(entry, ".pike") ||
                     has_suffix(entry, ".pmod")) &&
                    !Stdio.is_dir(full)) {
                    string content = Stdio.read_file(full);
                    if (!content) continue;
                    // Strip comments and strings before scanning
                    string clean = strip_comments_and_strings(content);
                    foreach (clean / "\n"; ; string line) {
                        string trimmed = String.trim_whites(line);
                        // import Foo; or import Foo.Bar; or import .Foo;
                        // We extract the first component (the dependency name)
                        array matches =
                            RE_IMPORT
                            ->split(trimmed);
                        if (matches && sizeof(matches) > 0) {
                            // Skip relative imports (leading dot)
                            if (matches[0][0] != '.') {
                                string first = (matches[0] / ".")[0];
                                imports[first] = 1;
                            }
                            continue;
                        }
                        // inherit Foo; or inherit Foo.Bar;
                        // We extract the first component
                        matches =
                            RE_INHERIT
                            ->split(trimmed);
                        if (matches && sizeof(matches) > 0) {
                            // Skip relative inherits (leading dot)
                            if (matches[0][0] != '.') {
                                string first = (matches[0] / ".")[0];
                                imports[first] = 1;
                            }
                            continue;
                        }
                        // #include <Foo.pmod/bar.h> or <Foo.Bar.pmod/baz.h>
                        matches =
                            RE_INCLUDE_PMOD
                            ->split(trimmed);
                        if (matches && sizeof(matches) > 0) {
                            string first = (matches[0] / ".")[0];
                            if (sizeof(first) > 0)
                                imports[first] = 1;
                            continue;
                        }
                        // #if constant(Foo) — conditional compilation references
                        matches =
                            RE_IF_CONSTANT
                            ->split(trimmed);
                        if (matches && sizeof(matches) > 0) {
                            imports[matches[0]] = 1;
                            continue;
                        }
                    }
                    // Scan raw content for string imports (import "foo";)
                    // since strip_comments_and_strings removes string contents
                    int in_block_comment = 0;
                    foreach (content / "\n"; ; string raw_line) {
                        string trimmed_raw = String.trim_whites(raw_line);
                        // Skip lines that are single-line comments
                        if (has_prefix(trimmed_raw, "//")) continue;
                        // Track block comment state
                        if (in_block_comment) {
                            if (has_value(trimmed_raw, "*/")) {
                                in_block_comment = 0;
                                // Content after */ may contain imports
                                // For simplicity, skip this line — rare edge case
                            }
                            continue;
                        }
                        // Single-line block comment: /* ... */
                        if (has_value(trimmed_raw, "/*") && has_value(trimmed_raw, "*/")) {
                            continue;
                        }
                        // Entering multi-line block comment
                        if (has_value(trimmed_raw, "/*")) {
                            in_block_comment = 1;
                            continue;
                        }
                        array matches =
                            RE_IMPORT_STRING
                            ->split(trimmed_raw);
                        if (matches && sizeof(matches) > 0) {
                            // Resolve the string path relative to the importing file
                            string resolved =
                                combine_path(dir, matches[0]);
                            // Extract the top-level module name from the resolved path
                            array(string) parts = resolved / "/";
                            foreach (parts; ; string p) {
                                if (sizeof(p) > 0) {
                                    // Strip .pmod/.pike suffix if present
                                    if (has_suffix(p, ".pmod"))
                                        p = p[..<5];
                                    else if (has_suffix(p, ".pike"))
                                        p = p[..<5];
                                    if (sizeof(p) > 0)
                                        imports[p] = 1;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        };
        collect_imports(real_dir, 0);

        // Get declared deps
        string pkg_json = pike_json_override
            || combine_path(real_dir, "pike.json");
        // If .pmod symlink, pike.json may be at store entry root (parent)
        if (!Stdio.exist(pkg_json) && has_suffix(mod_name, ".pmod")) {
            string parent_json = combine_path(real_dir, "..", "pike.json");
            if (Stdio.exist(parent_json))
                pkg_json = parent_json;
        }
        multiset(string) declared = (<>);
        if (Stdio.exist(pkg_json)) {
            foreach (parse_deps(pkg_json); ; array(string) dep)
                declared[dep[0]] = 1;
        }

        // Check each import
        foreach (indices(imports); ; string imp) {
            string mod_base = display_name(mod_name);
            if (imp == mod_base) continue;
            if (std_libs[imp]) continue;
            if (!declared[imp])
                warn(mod_name + " imports " + imp
                     + " but does not declare it as a dependency");
        }
    }
}
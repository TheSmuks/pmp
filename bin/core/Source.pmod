inherit Helpers;

//! Check if a source string represents a local path.
int(0..1) is_local_source(string s) {
    return s == "-" || has_prefix(s, "./") || has_prefix(s, "/");
}

//! Normalize a source URL: strip URL schemes (https://, http://, git://, ssh://),
//! trailing .git suffix, and #version suffix. Returns the clean host/path form.
string _normalize_source(string src) {
    // Strip #version suffix before normalizing
    if (has_value(src, "#"))
        src = (src / "#")[0];

    int had_scheme = 0;
    foreach (({"https://", "http://", "git://", "ssh://"}); ; string scheme)
        if (has_prefix(src, scheme)) {
            src = src[sizeof(scheme)..];
            had_scheme = 1;
            break;
        }

    // Strip SSH port number (ssh://host:port/path -> host/path)
    if (had_scheme && has_value(src, ":") && !has_prefix(src, "[")) {
        int first_slash = search(src, "/");
        int first_colon = search(src, ":");
        // Only strip if colon appears before first slash (port in authority)
        if (first_colon >= 0 && (first_slash < 0 || first_colon < first_slash)) {
            string after_port = src[first_colon + 1..];
            string after_slash = has_value(after_port, "/")
                ? after_port[search(after_port, "/")..] : "";
            src = src[..first_colon - 1] + after_slash;
        }
    }

    // Strip credentials user@host
    int at_pos = search(src, "@");
    if (at_pos >= 0) {
        int first_slash = search(src, "/");
        if (first_slash < 0 || at_pos < first_slash) {
            src = src[at_pos + 1..];
            // SCP-style: after stripping user@, host:path becomes host/path
            // Only convert if no scheme was present (SCP-style, not ssh://)
            if (!had_scheme) {
                int colon_pos = search(src, ":");
                if (colon_pos > 0) {
                    int slash_pos = search(src, "/");
                    if (slash_pos < 0 || colon_pos < slash_pos)
                        src = src[..colon_pos - 1] + "/" + src[colon_pos + 1..];
                }
            }
        }
    }

    // Strip trailing .git
    if (has_suffix(src, ".git")) src = src[..<4];

    return src;
}

//! Validate that a source URL has at least domain/owner/repo structure.
//! Returns 1 if valid, 0 if not. Does not call die().
int(0..1) _validate_source_format(string original, string clean) {
    array parts = clean / "/";
    // Filter out empty segments from double slashes
    parts = parts - ({ "" });
    if (sizeof(parts) < 3)
        return 0;
    string domain = parts[0];
    if (!has_value(domain, ".") && !has_value(domain, ":"))
        return 0;
    return 1;
}

//! Classify a source URL as "local", "github", "gitlab", or "selfhosted".
string detect_source_type(string src) {
    if (has_prefix(src, "./") || has_prefix(src, "/"))
        return "local";
    if (has_prefix(src, "file://"))
        die("file:// URLs are not supported — use local paths (./path or /absolute/path) instead");

    string clean = _normalize_source(src);
    if (!_validate_source_format(src, clean)) die("invalid source format: " + clean + " (expected domain/owner/repo)");
    string domain = (clean / "/")[0];

    switch (domain) {
        case "github.com":  return "github";
        case "gitlab.com":  return "gitlab";
        default:            return "selfhosted";
    }
}

//! Extract module name from last path segment.
//! Hyphens are replaced with underscores for valid Pike identifiers.
string source_to_name(string src) {
    string clean = _normalize_source(src);
    array(string) clean_parts = (clean / "/") - ({ "" });
    if (sizeof(clean_parts) < 1)
        die("cannot extract module name from: " + clean);
    return replace(clean_parts[-1], "-", "_");
}

//! Extract version from #suffix. Empty if none.
string source_to_version(string src) {
    if (has_value(src, "#")) {
        string ver = (src / "#")[1..] * "#";
        validate_version_tag(ver);
        return ver;
    }
    return "";
}

//! Normalize source and strip #version. Used for lockfile storage.
string source_strip_version(string src) {
    return _normalize_source(src);
}

//! Extract domain from a normalized source URL.
string source_to_domain(string src) {
    string clean = _normalize_source(src);
    return (clean / "/")[0];
}

//! Extract owner/repo path from a normalized source URL (after domain).
string source_to_repo_path(string src) {
    string clean = _normalize_source(src);
    if (!_validate_source_format(src, clean)) return "";
    array parts = clean / "/";
    if (sizeof(parts) < 3) return "";
    return parts[1..] * "/";
}

//! Validate a version tag for safe use in filenames.
//! Allows empty strings and valid semver tags.
//! Rejects tags containing /, \, .., ;, or null bytes.
void validate_version_tag(string tag) {
    if (sizeof(tag) == 0) return;  // empty is allowed
    if (has_value(tag, "/"))
        die("invalid version tag: contains '/': " + tag);
    if (has_value(tag, "\\"))
        die("invalid version tag: contains backslash: " + tag);
    if (has_value(tag, ".."))
        die("path traversal in version tag: " + tag);
    if (has_value(tag, ";"))
        die("invalid version tag: contains ';': " + tag);
    if (has_value(tag, "\0"))
        die("invalid version tag: contains null byte: " + tag);
    if (has_value(tag, "\n"))
        die("invalid version tag: contains newline");
}

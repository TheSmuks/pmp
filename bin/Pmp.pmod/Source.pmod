inherit .Helpers;

//! Normalize a source URL: strip URL schemes (https://, http://, git://, ssh://)
//! and trailing .git suffix. Returns the clean host/path form.
string _normalize_source(string src) {
    // Strip scheme
    if (has_prefix(src, "https://")) src = src[8..];
    else if (has_prefix(src, "http://")) src = src[7..];
    else if (has_prefix(src, "git://")) src = src[6..];
    else if (has_prefix(src, "ssh://")) src = src[6..];

    // Strip credentials user@host
    int at_pos = search(src, "@");
    if (at_pos > 0) {
        int first_slash = search(src, "/");
        if (first_slash < 0 || at_pos < first_slash) {
            src = src[at_pos + 1..];
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
    parts = filter(parts, lambda(string s) { return sizeof(s) > 0; });
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

    string clean = _normalize_source((src / "#")[0]);
    if (!_validate_source_format(src, clean)) die("invalid source format: " + src + " (expected domain/owner/repo)");
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
    string clean = _normalize_source((src / "#")[0]);
    array(string) clean_parts = (clean / "/") - ({ "" });
    if (sizeof(clean_parts) < 1)
        die("cannot extract module name from: " + src);
    return replace(clean_parts[-1], "-", "_");
}

//! Extract version from #suffix. Empty if none.
string source_to_version(string src) {
    if (has_value(src, "#")) {
        string ver = (src / "#")[1..] * "#";
        if (search(ver, "..") >= 0)
            die("path traversal in version tag: " + ver);
        if (search(ver, "/") >= 0 || search(ver, "\0") >= 0)
            die("invalid version tag: " + ver);
        return ver;
    }
    return "";
}

//! Normalize source and strip #version. Used for lockfile storage.
string source_strip_version(string src) {
    return _normalize_source((src / "#")[0]);
}

//! Extract domain from a normalized source URL.
string source_to_domain(string src) {
    string clean = _normalize_source((src / "#")[0]);
    return (clean / "/")[0];
}

//! Extract owner/repo path from a normalized source URL (after domain).
string source_to_repo_path(string src) {
    string clean = _normalize_source((src / "#")[0]);
    if (!_validate_source_format(src, clean)) return "";
    array parts = clean / "/";
    if (sizeof(parts) < 3) return "";
    return parts[1..] * "/";
}

//! Validate a version tag for safe use in filenames.
//! Allows empty strings and valid semver tags.
//! Rejects tags containing /, \\, .., ;, or null bytes.
void validate_version_tag(string tag) {
    if (sizeof(tag) == 0) return;  // empty is allowed
    if (search(tag, "/") >= 0)
        die("invalid version tag: contains '/': " + tag);
    if (search(tag, "\\") >= 0)
        die("invalid version tag: contains backslash: " + tag);
    if (search(tag, "..") >= 0)
        die("invalid version tag: contains '..': " + tag);
    if (search(tag, ";") >= 0)
        die("invalid version tag: contains ';': " + tag);
    if (search(tag, "\0") >= 0)
        die("invalid version tag: contains null byte: " + tag);
}
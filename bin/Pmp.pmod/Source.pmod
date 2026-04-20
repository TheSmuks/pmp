inherit .Helpers;

//! Classify a source URL as "local", "github", "gitlab", or "selfhosted".
string detect_source_type(string src) {
    if (has_prefix(src, "./") || has_prefix(src, "/"))
        return "local";

    string clean = (src / "#")[0];
    string domain = (clean / "/")[0];

    if (sizeof(clean / "/") >= 2 && has_value(domain, ".")) {
        switch (domain) {
            case "github.com":  return "github";
            case "gitlab.com":  return "gitlab";
            default:            return "selfhosted";
        }
    }

    if (has_value(clean, "/"))
        die("unsupported source format: " + src +
            " (use full URL like github.com/owner/repo)");

    die("registry not supported yet — use full URL "
        "(e.g. github.com/owner/repo)");
}

//! Extract module name from last path segment.
string source_to_name(string src) {
    string clean = (src / "#")[0];
    return (clean / "/")[-1];
}

//! Extract version from #suffix. Empty if none.
string source_to_version(string src) {
    if (has_value(src, "#"))
        return (src / "#")[1..] * "#";
    return "";
}

//! Strip #version from source.
string source_strip_version(string src) {
    return (src / "#")[0];
}

//! Extract domain from a host URL.
string source_to_domain(string src) {
    string clean = (src / "#")[0];
    return (clean / "/")[0];
}

//! Extract owner/repo path from host URL (after domain).
string source_to_repo_path(string src) {
    string clean = (src / "#")[0];
    string domain = (clean / "/")[0];
    // Everything after domain/
    array parts = clean / "/";
    if (sizeof(parts) < 3) return "";
    return parts[1..] * "/";
}

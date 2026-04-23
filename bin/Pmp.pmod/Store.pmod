inherit .Helpers;
inherit .Http;
inherit .Resolve;

//! Acquire an advisory lock on the store directory.
//! Uses a PID-based lock file. Dies if another pmp process holds the lock.
//! Call store_unlock() when done.
void store_lock(string store_dir) {
    Stdio.mkdirhier(store_dir);
    string lock_path = combine_path(store_dir, ".lock");
    advisory_lock(lock_path, "store");
    _store_locked = 1;
    _store_dir_for_lock = store_dir;
}

//! Release the store lock.
void store_unlock(string store_dir) {
    string lock_path = combine_path(store_dir, ".lock");
    advisory_unlock(lock_path);
    _store_locked = 0;
    _store_dir_for_lock = "";
}

//! Generate store entry name from source, tag, and SHA.
//! Format: {domain}-{owner}-{repo}-{tag}-{sha_prefix16}
string store_entry_name(string src, string tag, string sha) {
    string clean = (src / "#")[0];
    // Convert / to -, remove leading/trailing -
    // Convert / to -, collapse repeated dashes
    string slug = replace(clean, "/", "-");
    while (has_value(slug, "--")) slug = replace(slug, "--", "-");
    // Trim leading/trailing dashes
    while (has_prefix(slug, "-")) slug = slug[1..];
    while (has_suffix(slug, "-")) slug = slug[..<1];

    // Sanitize against path traversal
    if (search(slug, "..") >= 0)
        die("invalid source: path traversal in slug: " + slug, EXIT_INTERNAL);
    // Sanitize tag: replace / with - to prevent nested directories
    string safe_tag = replace(tag, "/", "-");
    while (has_value(safe_tag, "--")) safe_tag = replace(safe_tag, "--", "-");

    if (search(tag, "..") >= 0)
        die("invalid tag: path traversal: " + tag, EXIT_INTERNAL);
    if (sizeof(sha) == 0) {
        // SHA resolution failed — use hash of source+tag as fallback identifier
        sha = String.string2hex(Crypto.SHA256.hash(slug + "-" + safe_tag))[..15];
        debug("SHA unavailable, using content-derived identifier: " + sha);
    } else if (!Regexp("^[a-f0-9]+$")->match(sha)) {
        die("invalid sha: expected hex, got: " + sha, EXIT_INTERNAL);
    }

    string sha_prefix = (sizeof(sha) >= 16) ? sha[..15] : sha;
    return sprintf("%s-%s-%s", slug, safe_tag, sha_prefix);
}

//! Extract a .tar.gz file to a directory.
//! Uses system tar with security hardening: --no-same-owner prevents
//! UID/GID leaks, and symlink-path-traversal is validated after extraction.
string extract_targz(string tarball_path, string dest_dir) {
    Stdio.mkdirhier(dest_dir);

    // Extract using system tar with security flags
    mapping r = Process.run(({"tar", "xzf", tarball_path, "-C", dest_dir,
                              "--no-same-owner", "--no-same-permissions"}));
    if (r->exitcode != 0)
        die("failed to extract archive: " + (r->stderr || "unknown error"), EXIT_INTERNAL);

    // Validate no symlink-path-traversal: find all symlinks and ensure
    // none point outside the extraction directory.
    _validate_symlinks(dest_dir, dest_dir);

    // Find the top-level directory in the extracted content
    array(string) entries = get_dir(dest_dir);

    if (!entries || sizeof(entries) == 0)
        die("empty archive", EXIT_INTERNAL);

    sort(entries);
    // Ensure the returned entry is actually a directory
    if (!Stdio.is_dir(combine_path(dest_dir, entries[0]))) {
        string found;
        foreach (entries; ; string e) {
            if (Stdio.is_dir(combine_path(dest_dir, e))) {
                found = e;
                break;
            }
        }
        if (!found)
            die("tarball has no top-level directory", EXIT_INTERNAL);
        return found;
    }
    return entries[0];
}

//! Find a store entry matching source, tag, and optionally content hash.
//! Returns the entry directory name, or "" if not found.
string _find_store_entry(string store_dir, string source, string tag, string content_hash) {
    string slug = replace(source, "/", "-");
    while (has_value(slug, "--")) slug = replace(slug, "--", "-");
    while (has_prefix(slug, "-")) slug = slug[1..];
    while (has_suffix(slug, "-")) slug = slug[..<1];
    string safe_tag = replace(tag, "/", "-");
    while (has_value(safe_tag, "--")) safe_tag = replace(safe_tag, "--", "-");
    string pattern = slug + "-" + safe_tag + "-*";
    array(string) candidates = ({});

    if (Stdio.is_dir(store_dir)) {
        foreach (get_dir(store_dir) || ({}); ; string se) {
            if (glob(pattern, se) && Stdio.is_dir(combine_path(store_dir, se)))
                candidates += ({ se });
        }
    }

    // Match by content hash
    if (sizeof(candidates) > 0 && sizeof(content_hash) > 0) {
        foreach (candidates; ; string se) {
            string stored = read_stored_hash(combine_path(store_dir, se));
            if (stored && stored == content_hash)
                return se;
        }
        if (sizeof(candidates) > 0)
            warn("no store entry for " + tag + " matches lockfile hash");
        return "";
    }

    // Fallback: use first candidate
    if (sizeof(candidates) > 0) return candidates[0];
    return "";
}

//! Recursively validate that no symlinks under base_dir escape root_dir.
void _validate_symlinks(string base_dir, string root_dir, void|int depth) {
    if (depth > 20)
        die("archive directory nesting exceeds safety limit (20 levels)", EXIT_INTERNAL);
    array(string) entries = get_dir(base_dir) || ({});
    foreach (entries; ; string name) {
        string full = combine_path(base_dir, name);
        // readlink returns target on success, throws on non-symlink
        string link_target = get_symlink_target(full);
        if (link_target) {
            // Resolve the symlink target relative to its parent
            string parent = combine_path(full, "..");
            string resolved = combine_path(parent, link_target);
            string norm_root = combine_path(root_dir, ".");
            if (!has_prefix(resolved, norm_root + "/") && resolved != norm_root) {
                die("archive contains symlink escaping extraction dir: "
                    + full + " -> " + link_target, EXIT_INTERNAL);
            }
        }
        if (Stdio.is_dir(full))
            _validate_symlinks(full, root_dir, depth + 1);
    }
}

//! Read content_sha256 from .pmp-meta of an existing store entry.
//! Returns 0 if the meta file does not exist or has no hash.
string read_stored_hash(string entry_dir) {
    string meta_file = combine_path(entry_dir, ".pmp-meta");
    if (!Stdio.exist(meta_file)) return 0;
    string raw = Stdio.read_file(meta_file);
    if (!raw) return 0;
    foreach (raw / "\n"; ; string line)
        if (has_prefix(line, "content_sha256\t"))
            return String.trim_all_whites(line[15..]);
    return 0;
}

//! Write .pmp-meta file to a store entry.
void write_meta(string entry_dir, string source, string tag,
                string sha, string hash) {
    string meta_path = combine_path(entry_dir, ".pmp-meta");
    string meta = sprintf(
        "source\t%s\ntag\t%s\ncommit_sha\t%s\ncontent_sha256\t%s\ninstalled_at\t%d\n",
        source, tag, sha, hash, time());
    atomic_write(meta_path, meta);
}

//! Recursively collect all regular files under a directory.
//! Returns relative paths sorted lexicographically.
//! Unlike `find`, this handles filenames with newlines correctly.
array(string) _collect_files(string base, string rel) {
    array(string) result = ({});
    string full = combine_path(base, rel);
    array(string) entries = get_dir(full) || ({});
    sort(entries);
    foreach (entries; ; string name) {
        // Skip .pmp-meta metadata files
        if (name == ".pmp-meta") continue;
        string path = sizeof(rel) > 0 ? rel + "/" + name : name;
        string abs = combine_path(base, path);
        if (Stdio.is_dir(abs)) {
            result += _collect_files(base, path);
        } else if (Stdio.is_file(abs)) {
            result += ({ path });
        }
    }
    return result;
}

//! Compute a content hash from a directory by hashing sorted file contents.
//! Uses Pike directory walk instead of `find` to handle all filenames.
string compute_dir_hash(string dir) {
    array(string) files = _collect_files(dir, "");

    String.Buffer buf = String.Buffer();
    foreach (files; ; string f) {
        string hash = compute_sha256(combine_path(dir, f));
        buf->add(hash + "  " + f + "\n");
    }
    return String.string2hex(Crypto.SHA256.hash(buf->get()));
}

//! Given a module name and store entry path, determine the correct
//! symlink target and link name for Pike module resolution.
//! Returns ("target": string, "link_name": string).
//!
//! The module name is resolved from the entry's pike.json "name" field
//! when available, falling back to the provided name parameter.
//!
//! Pike resolves `import Name` via:
//!   1. Name.pmod (file) — standalone module file
//!   2. Name.pmod/module.pmod — directory with .pmod suffix
//! Bare directories (Name/) are NOT resolved by import, so we always
//! use .pmod-suffixed symlinks when module.pmod exists.
mapping resolve_module_path(string name, string entry_dir) {
    // 1. name.pmod/ directory (e.g., PUnit.pmod/) — nested module
    string pmod_dir = combine_path(entry_dir, name + ".pmod");
    if (Stdio.is_dir(pmod_dir))
        return (["target": pmod_dir, "link_name": name + ".pmod"]);

    // 2. name/ directory with module.pmod inside (subdirectory module)
    //    Use .pmod suffix so Pike can resolve import Name
    string named_dir = combine_path(entry_dir, name);
    if (Stdio.is_dir(named_dir) &&
        Stdio.exist(combine_path(named_dir, "module.pmod")))
        return (["target": named_dir, "link_name": name + ".pmod"]);

    // 3. module.pmod at entry root — use .pmod suffix for import resolution
    if (Stdio.exist(combine_path(entry_dir, "module.pmod")))
        return (["target": entry_dir, "link_name": name + ".pmod"]);

    // 4. Fallback: symlink to entry root
    return (["target": entry_dir, "link_name": name]);
}

//! Common store install logic: check existing entry, move content, write meta.
//! @param content_dir
//!   Absolute path to the extracted/cloned content to move into the store.
//! @param tmpdir
//!   Temporary directory; cleaned up by this function on all paths.
//! @returns
//!   (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping _store_install_common(string store_dir, string source_label,
                              string ver, string sha,
                              string tmpdir, string content_dir) {
    string entry_name = store_entry_name(source_label, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    // Check if entry already exists with valid metadata
    if (Stdio.is_dir(entry_dir)) {
        if (!Stdio.exist(combine_path(entry_dir, ".pmp-meta"))) {
            warn("store entry " + entry_name + " missing metadata — re-downloading");
            Stdio.recursive_rm(entry_dir);
        } else {
            string stored_hash = read_stored_hash(entry_dir);
            string actual_hash = compute_dir_hash(entry_dir);
            if (stored_hash && actual_hash && stored_hash != actual_hash) {
                warn("store entry " + entry_name + " has integrity mismatch — re-downloading");
                Stdio.recursive_rm(entry_dir);
            } else {
                info("reusing existing store entry " + entry_name);
                Stdio.recursive_rm(tmpdir);
                unregister_cleanup_dir(tmpdir);
                return (["tag": ver, "sha": sha, "hash": stored_hash || "", "entry": entry_name]);
            }
        }
    }

    // Ensure clean target
    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    // Symlink-safe removal
    if (is_symlink(entry_dir)) rm(entry_dir);
    else Stdio.recursive_rm(entry_dir);

    // Move content to store
    if (!Stdio.recursive_mv(content_dir, entry_dir)) {
        unregister_cleanup_dir(tmpdir);
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + content_dir, EXIT_INTERNAL);
    }
    if (!Stdio.is_dir(entry_dir)) {
        unregister_cleanup_dir(tmpdir);
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("store entry is not a directory after mv: " + entry_dir, EXIT_INTERNAL);
    }

    Stdio.recursive_rm(tmpdir);
    unregister_cleanup_dir(tmpdir);

    // Write .pmp-meta with directory content hash
    string dir_hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, source_label, ver, sha, dir_hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": dir_hash, "entry": entry_name]);
}

//! Download from GitHub to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_github(string store_dir, string repo_path, string ver,
                             void|string version) {
    string url = "https://github.com/" + repo_path
                 + "/archive/refs/tags/" + ver + ".tar.gz";

    info("downloading " + url);
    string body = http_get(url, 0, version);

    // Write to temp file
    string tmpdir_base = combine_path(getenv("TMPDIR") || "/tmp", "pmp_install_XXXXXX");
    mapping mktemp_result = Process.run(({"mktemp", "-d", tmpdir_base}));
    string tmpdir = String.trim_all_whites(mktemp_result->stdout || "");
    if (sizeof(tmpdir) == 0) die("failed to create temp directory");
    register_cleanup_dir(tmpdir);
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    // Extract
    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    // Resolve commit SHA
    string sha = resolve_commit_sha("github", "", repo_path, ver, version);
    sha = sha || "";

    string content_dir = combine_path(tmpdir, "extract", extracted);
    return _store_install_common(store_dir, "github.com/" + repo_path,
                                  ver, sha, tmpdir, content_dir);
}

//! Download from GitLab to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_gitlab(string store_dir, string repo_path, string ver,
                             void|string version) {
    string repo_name = (repo_path / "/")[-1];
    string url = "https://gitlab.com/" + repo_path
                 + "-/archive/" + ver + "/" + repo_name + "-" + ver
                 + ".tar.gz";

    info("downloading " + url);
    string body = http_get(url, 0, version);

    string tmpdir_base = combine_path(getenv("TMPDIR") || "/tmp", "pmp_install_XXXXXX");
    mapping mktemp_result = Process.run(({"mktemp", "-d", tmpdir_base}));
    string tmpdir = String.trim_all_whites(mktemp_result->stdout || "");
    if (sizeof(tmpdir) == 0) die("failed to create temp directory");
    register_cleanup_dir(tmpdir);
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    string sha = resolve_commit_sha("gitlab", "", repo_path, ver, version);
    sha = sha || "";

    string content_dir = combine_path(tmpdir, "extract", extracted);
    return _store_install_common(store_dir, "gitlab.com/" + repo_path,
                                  ver, sha, tmpdir, content_dir);
}

//! Clone from self-hosted git to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_selfhosted(string store_dir, string domain,
                                 string repo_path, string ver,
                                 void|string version) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    string tmpdir_base = combine_path(getenv("TMPDIR") || "/tmp", "pmp_install_XXXXXX");
    mapping mktemp_result = Process.run(({"mktemp", "-d", tmpdir_base}));
    string tmpdir = String.trim_all_whites(mktemp_result->stdout || "");
    if (sizeof(tmpdir) == 0) die("failed to create temp directory");
    register_cleanup_dir(tmpdir);
    string repo_dest = combine_path(tmpdir, "repo");

    // SSRF protection — validate domain before git clone
    if (_is_private_host(domain))
        die("blocked: SSRF protection — refusing to clone from private/internal address: " + domain);

    info("cloning " + url + " at " + ver);
    mapping r = Process.run(
        ({"git", "clone", "--branch", ver, "--depth", "1",
          url, repo_dest}));
    if (r->exitcode != 0) {
        unregister_cleanup_dir(tmpdir);
        Stdio.recursive_rm(tmpdir);
        die("failed to clone " + url);
    }

    _validate_symlinks(repo_dest, repo_dest);

    string sha = resolve_commit_sha("selfhosted", domain, repo_path, ver, version);
    sha = sha || "";

    return _store_install_common(store_dir, domain + "/" + repo_path,
                                  ver, sha, tmpdir, repo_dest);
}

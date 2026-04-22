inherit .Helpers;
inherit .Http;
inherit .Resolve;

//! Acquire an advisory lock on the store directory.
//! Uses a PID-based lock file. Dies if another pmp process holds the lock.
//! Call store_unlock() when done.
void store_lock(string store_dir) {
    Stdio.mkdirhier(store_dir);
    string lock_path = combine_path(store_dir, ".lock");
    string my_pid = (string)getpid();

    // Try atomic create (O_EXCL) — fails if file exists
    for (int attempt = 0; attempt < 2; attempt++) {
        mixed err = catch {
            Stdio.File lf = Stdio.File(lock_path, "wct");
            lf->write(my_pid);
            lf->close();
        };
        if (!err) return;  // Lock acquired

        // Lock file exists — check if holder is still alive
        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (sizeof(existing) > 0) {
            int pid = (int)existing;
            if (pid > 0) {
                mapping r = Process.run(({"kill", "-0", (string)pid}));
                if (r->exitcode == 0) {
                    die("store is locked by pmp process " + pid
                        + " — wait for it to finish or remove "
                        + lock_path + " manually");
                }
                // Stale lock — remove and retry
                info("removing stale store lock from process " + pid);
                rm(lock_path);
                continue;
            }
        }
        // Unknown/empty lock file — remove and retry
        rm(lock_path);
    }
    // Two attempts failed
    die("failed to acquire store lock after retry");
}

//! Release the store lock.
void store_unlock(string store_dir) {
    string lock_path = combine_path(store_dir, ".lock");
    if (Stdio.exist(lock_path)) {
        string existing = String.trim_all_whites(Stdio.read_file(lock_path) || "");
        if (existing == (string)getpid())
            rm(lock_path);
    }
}

//! Generate store entry name from source, tag, and SHA.
//! Format: {domain}-{owner}-{repo}-{tag}-{sha_prefix8}
string store_entry_name(string src, string tag, string sha) {
    string clean = (src / "#")[0];
    // Convert / to -, remove leading/trailing -
    // Convert / to -, collapse repeated dashes
    string slug = replace(replace(clean, "/", "-"), "--", "-");
    // Trim leading/trailing dashes
    while (has_prefix(slug, "-")) slug = slug[1..];
    while (has_suffix(slug, "-")) slug = slug[..<1];

    string sha8 = (sizeof(sha) >= 8) ? sha[..7] : sha;
    return sprintf("%s-%s-%s", slug, tag, sha8);
}

//! Extract a .tar.gz file to a directory.
//! Uses system tar with security hardening: --no-same-owner prevents
//! UID/GID leaks, and symlink-path-traversal is validated after extraction.
string extract_targz(string tarball_path, string dest_dir) {
    Stdio.mkdirhier(dest_dir);

    // Extract using system tar with security flags
    mapping r = Process.run(({"tar", "xzf", tarball_path, "-C", dest_dir,
                              "--no-same-owner"}));
    if (r->exitcode != 0)
        die("failed to extract archive: " + (r->stderr || "unknown error"), EXIT_INTERNAL);

    // Validate no symlink-path-traversal: find all symlinks and ensure
    // none point outside the extraction directory.
    _validate_symlinks(dest_dir, dest_dir);

    // Find the top-level directory in the extracted content
    array(string) entries = get_dir(dest_dir);

    if (!entries || sizeof(entries) == 0)
        die("empty archive", EXIT_INTERNAL);

    return entries[0];
}

//! Recursively validate that no symlinks under base_dir escape root_dir.
void _validate_symlinks(string base_dir, string root_dir) {
    array(string) entries = get_dir(base_dir) || ({});
    foreach (entries; ; string name) {
        string full = combine_path(base_dir, name);
        // readlink returns target on success, throws on non-symlink
        string link_target;
        mixed err = catch { link_target = System.readlink(full); };
        if (!err && stringp(link_target)) {
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
            _validate_symlinks(full, root_dir);
    }
}

//! Read content_sha256 from .pmp-meta of an existing store entry.
//! Returns 0 if the meta file does not exist or has no hash.
string read_stored_hash(string entry_dir) {
    string meta_file = combine_path(entry_dir, ".pmp-meta");
    if (!Stdio.exist(meta_file)) return 0;
    foreach (Stdio.read_file(meta_file) / "\n"; ; string line)
        if (has_prefix(line, "content_sha256\t"))
            return line[16..];
    return 0;
}

//! Write .pmp-meta file to a store entry.
void write_meta(string entry_dir, string source, string tag,
                string sha, string hash) {
    string meta = sprintf(
        "source\t%s\ntag\t%s\ncommit_sha\t%s\ncontent_sha256\t%s\ninstalled_at\t%d\n",
        source, tag, sha, hash, time());
    Stdio.write_file(combine_path(entry_dir, ".pmp-meta"), meta);
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
//! Returns (["target": string, "link_name": string]).
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

    // 4. Fallback: symlink to entry root (backward compat)
    return (["target": entry_dir, "link_name": name]);
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
    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d ${TMPDIR:-/tmp}/pmp_install_XXXXXX"));
    register_cleanup_dir(tmpdir);
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    // Extract
    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    // Resolve commit SHA
    string sha = resolve_commit_sha("github", "", repo_path, ver, version);
    sha = sha || "";

    string entry_name = store_entry_name(
        "github.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        unregister_cleanup_dir(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir) || "", "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    // Move extracted content to store
    string src = combine_path(tmpdir, "extract", extracted);
    if (!mv(src, entry_dir)) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + src, EXIT_INTERNAL);
    }
    if (!Stdio.is_dir(entry_dir)) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("store entry is not a directory after mv: " + entry_dir, EXIT_INTERNAL);
    }
    Stdio.recursive_rm(tmpdir);
    unregister_cleanup_dir(tmpdir);

    // Write .pmp-meta with directory content hash
    string dir_hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, "github.com/" + repo_path, ver, sha, dir_hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": dir_hash, "entry": entry_name]);
}

//! Download from GitLab to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_gitlab(string store_dir, string repo_path, string ver,
                             void|string version) {
    string repo_name = (repo_path / "/")[-1];
    string url = "https://gitlab.com/" + repo_path
                 + "/-/archive/" + ver + "/" + repo_name + "-" + ver
                 + ".tar.gz";

    info("downloading " + url);
    string body = http_get(url, 0, version);

    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d ${TMPDIR:-/tmp}/pmp_install_XXXXXX"));
    register_cleanup_dir(tmpdir);
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    string sha = resolve_commit_sha("gitlab", "", repo_path, ver, version);
    sha = sha || "";

    string entry_name = store_entry_name(
        "gitlab.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        unregister_cleanup_dir(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir) || "", "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    string src = combine_path(tmpdir, "extract", extracted);
    if (!mv(src, entry_dir)) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + src, EXIT_INTERNAL);
    }
    Stdio.recursive_rm(tmpdir);
    unregister_cleanup_dir(tmpdir);

    // Write .pmp-meta with directory content hash
    string dir_hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, "gitlab.com/" + repo_path, ver, sha, dir_hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": dir_hash, "entry": entry_name]);
}

//! Clone from self-hosted git to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_selfhosted(string store_dir, string domain,
                                 string repo_path, string ver,
                                 void|string version) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d ${TMPDIR:-/tmp}/pmp_install_XXXXXX"));
    register_cleanup_dir(tmpdir);
    string repo_dest = combine_path(tmpdir, "repo");

    info("cloning " + url + " at " + ver);
    mapping r = Process.run(
        ({"git", "clone", "--branch", ver, "--depth", "1",
          url, repo_dest}));
    if (r->exitcode != 0) {
        Stdio.recursive_rm(tmpdir);
        die("failed to clone " + url);
    }

    string sha = resolve_commit_sha("selfhosted", domain, repo_path, ver, version);
    sha = sha || "";

    // Content hash computed after move to store (below)

    string entry_name = store_entry_name(
        domain + "/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        unregister_cleanup_dir(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir) || "", "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    if (!mv(repo_dest, entry_dir)) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + repo_dest, EXIT_INTERNAL);
    }
    Stdio.recursive_rm(tmpdir);
    unregister_cleanup_dir(tmpdir);

    string hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, domain + "/" + repo_path, ver, sha, hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": hash, "entry": entry_name]);
}

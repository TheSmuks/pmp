inherit .Helpers;
inherit .Http;
inherit .Resolve;

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
//! Uses system tar for reliable extraction across platforms.
string extract_targz(string tarball_path, string dest_dir) {
    Stdio.mkdirhier(dest_dir);

    // Extract using system tar (more reliable than Filesystem.Tar across builds)
    mapping r = Process.run(({"tar", "xzf", tarball_path, "-C", dest_dir}));
    if (r->exitcode != 0)
        die("failed to extract archive: " + (r->stderr || "unknown error"));

    // Find the top-level directory in the extracted content
    array(string) entries = get_dir(dest_dir);

    if (!entries || sizeof(entries) == 0)
        die("empty archive");

    return entries[0];
}

//! Read content_sha256 from .pmp-meta of an existing store entry.
string read_stored_hash(string entry_dir) {
    string meta_file = combine_path(entry_dir, ".pmp-meta");
    if (!Stdio.exist(meta_file)) return "unknown";
    foreach (Stdio.read_file(meta_file) / "\n"; ; string line)
        if (has_prefix(line, "content_sha256\t"))
            return line[16..];
    return "unknown";
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
    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d /tmp/pmp_install_XXXXXX"));
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    // Extract
    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    // Resolve commit SHA
    string sha = resolve_commit_sha("github", "", repo_path, ver, version);
    sha = sha || "unknown";

    string entry_name = store_entry_name(
        "github.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir), "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    // Move extracted content to store
    string src = combine_path(tmpdir, "extract", extracted);
    mapping mv_r = Process.run(({"mv", src, entry_dir}));
    if (mv_r->exitcode != 0) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + (mv_r->stderr || ""));
    }
    if (!Stdio.is_dir(entry_dir)) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("store entry is not a directory after mv: " + entry_dir);
    }
    Stdio.recursive_rm(tmpdir);

    // Write .pmp-meta
    write_meta(entry_dir, "github.com/" + repo_path, ver, sha, hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": hash, "entry": entry_name]);
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

    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d /tmp/pmp_install_XXXXXX"));
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    string sha = resolve_commit_sha("gitlab", "", repo_path, ver, version);
    sha = sha || "unknown";

    string entry_name = store_entry_name(
        "gitlab.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir), "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    string src = combine_path(tmpdir, "extract", extracted);
    mapping mv_r = Process.run(({"mv", src, entry_dir}));
    if (mv_r->exitcode != 0) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + (mv_r->stderr || ""));
    }
    Stdio.recursive_rm(tmpdir);

    write_meta(entry_dir, "gitlab.com/" + repo_path, ver, sha, hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": hash, "entry": entry_name]);
}

//! Clone from self-hosted git to store.
//! Returns (["tag":ver, "sha":sha, "hash":hash, "entry":entry_name]).
mapping store_install_selfhosted(string store_dir, string domain,
                                 string repo_path, string ver,
                                 void|string version) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d /tmp/pmp_install_XXXXXX"));
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
    sha = sha || "unknown";

    // Compute content hash from sorted file listing
    string hash = compute_dir_hash(repo_dest);

    string entry_name = store_entry_name(
        domain + "/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        return (["tag": ver, "sha": sha, "hash": read_stored_hash(entry_dir), "entry": entry_name]);
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    mapping mv_r = Process.run(({"mv", repo_dest, entry_dir}));
    if (mv_r->exitcode != 0) {
        Stdio.recursive_rm(tmpdir);
        Stdio.recursive_rm(entry_dir);
        die("failed to move to store: " + (mv_r->stderr || ""));
    }
    Stdio.recursive_rm(tmpdir);

    write_meta(entry_dir, domain + "/" + repo_path, ver, sha, hash);

    info("stored " + entry_name);
    return (["tag": ver, "sha": sha, "hash": hash, "entry": entry_name]);
}

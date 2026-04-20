#!/usr/bin/env pike
// pmp — Pike Module Package Manager
// Native Pike implementation — no curl, tar, sha256sum, or sed-JSON required.
// Only external tools: gunzip (for .tar.gz decompression), git (self-hosted only).

constant PMP_VERSION = "0.2.0";

// ── Configuration ──────────────────────────────────────────────────

string pike_bin;
string global_dir;
string local_dir = "./modules";
string store_dir;
string pike_json = "./pike.json";
string lockfile_path = "./pike.lock";

// ── Accumulated lockfile entries during install ─────────────────────

array(array(string)) lock_entries = ({});

// ── Cycle detection ────────────────────────────────────────────────

multiset(string) visited = (<>);

// ── Helpers ────────────────────────────────────────────────────────

void die(string msg) {
    werror("pmp: %s\n", msg);
    exit(1);
}

void info(string msg) {
    write("pmp: %s\n", msg);
}

void warn(string msg) {
    werror("pmp: warning: %s\n", msg);
}

void need_cmd(string name) {
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    if (!Process.locate_binary(search_path, name))
        die("requires " + name);
}

//! Read a field from pike.json using proper JSON parsing.
void|string json_field(string field, void|string file) {
    string path = file || pike_json;
    if (!Stdio.exist(path)) return 0;
    string raw = Stdio.read_file(path);
    if (!raw) return 0;
    mapping|mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) return 0;
    // Check top-level field
    if (!zero_type(data[field])) return data[field];
    return 0;
}

//! Walk up from directory to find pike.json, resolving symlinks.
void|string find_project_root(void|string dir) {
    string d = dir || getcwd();
    while (d != "/") {
        if (Stdio.exist(combine_path(d, "pike.json")))
            return d;
        string parent = combine_path(d, "..");
        if (parent == d) break;
        d = parent;
    }
    return 0;
}

//! Compute SHA-256 hex digest of a file.
string compute_sha256(string path) {
    string data = Stdio.read_file(path);
    if (!data) return "unknown";
    return String.string2hex(Crypto.SHA256.hash(data));
}

// ── Source type detection ──────────────────────────────────────────
//
// Source types from URL format:
//   github.com/owner/repo       -> "github"
//   gitlab.com/owner/repo       -> "gitlab"
//   git.example.com/owner/repo  -> "selfhosted"
//   ./relative/path             -> "local"
//   /absolute/path              -> "local"
//   barename                    -> error (registry not supported)

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

// ── Store helpers ──────────────────────────────────────────────────

//! Generate store entry name from source, tag, and SHA.
//! Format: {domain}-{owner}-{repo}-{tag}-{sha_prefix8}
string store_entry_name(string src, string tag, string sha) {
    string clean = (src / "#")[0];
    // Convert / to -, remove leading/trailing -
    string slug = replace(clean, "/", "-");
    slug = String.Buffer()->add(
        replace(sprintf("%s", slug),
                (["//": "-", "--": "-"])))->get();
    // Trim leading/trailing dashes
    while (has_prefix(slug, "-")) slug = slug[1..];
    while (has_suffix(slug, "-")) slug = slug[..<1];

    string sha8 = (sizeof(sha) >= 8) ? sha[..7] : sha;
    return sprintf("%s-%s-%s", slug, tag, sha8);
}

// ── HTTP helpers ───────────────────────────────────────────────────

//! HTTP GET with error handling. Returns body string or dies.
string http_get(string url, void|mapping(string:string) headers) {
    Protocols.HTTP.Query con;
    mapping request_headers = ([
        "user-agent": "pmp/" + PMP_VERSION,
    ]);

    if (headers)
        request_headers |= headers;

    mixed err = catch {
        con = Protocols.HTTP.do_method("GET", url, 0, request_headers);
    };

    if (err) {
        die("failed to fetch " + url + ": " + describe_error(err));
    }
    if (!con) {
        die("failed to connect to " + url);
    }
    if (con->status != 200) {
        die(sprintf("HTTP %d fetching %s", con->status, url));
    }
    string body = con->data();
    if (!body) {
        die("no data from " + url);
    }
    return body;
}

//! HTTP GET returning ({status, body}) — doesn't die on non-200.
array(int|string) http_get_safe(string url, void|mapping(string:string) headers) {
    Protocols.HTTP.Query con;
    mapping request_headers = ([
        "user-agent": "pmp/" + PMP_VERSION,
    ]);

    if (headers)
        request_headers |= headers;

    mixed err = catch {
        con = Protocols.HTTP.do_method("GET", url, 0, request_headers);
    };

    if (err || !con)
        return ({ 0, "" });

    string body = con->data() || "";
    return ({ con->status, body });
}

// ── Version resolution (returns ({tag, commit_sha})) ───────────────

//! Build auth headers if GITHUB_TOKEN is set.
void|mapping github_auth_headers() {
    string token = getenv("GITHUB_TOKEN");
    if (!token || token == "") return 0;
    info("using GITHUB_TOKEN for authentication");
    return (["authorization": "token " + token]);
}

//! Get latest tag from GitHub.
array(string) latest_tag_github(string repo_path) {
    string url = "https://api.github.com/repos/" + repo_path + "/tags";
    string body = http_get(url, github_auth_headers());

    mixed data;
    mixed err = catch { data = Standards.JSON.decode(body); };
    if (err || !arrayp(data) || sizeof(data) == 0)
        return ({ "", "" });

    mapping first = data[0];
    string tag = first->name || "";
    string sha = "";
    // The tags API returns objects with .commit.sha
    if (mappingp(first->commit))
        sha = first->commit->sha || "";

    if (sha == "") {
        // Fallback: fetch commit SHA from the ref endpoint
        array(int|string) result = http_get_safe(
            "https://api.github.com/repos/" + repo_path + "/commits/" + tag,
            github_auth_headers());
        if (result[0] == 200) {
            mixed commit_data;
            err = catch { commit_data = Standards.JSON.decode(result[1]); };
            if (!err && mappingp(commit_data))
                sha = commit_data->sha || "";
        }
    }
    return ({ tag, sha || "unknown" });
}

//! Get latest tag from GitLab.
array(string) latest_tag_gitlab(string repo_path) {
    string encoded = replace(repo_path, "/", "%2F");
    string url = "https://gitlab.com/api/v4/projects/"
                 + encoded + "/repository/tags";
    string body = http_get(url);

    mixed data;
    mixed err = catch { data = Standards.JSON.decode(body); };
    if (err || !arrayp(data) || sizeof(data) == 0)
        return ({ "", "" });

    mapping first = data[0];
    string tag = first->name || "";
    string sha = "";
    // GitLab tags API returns .commit.id
    if (mappingp(first->commit))
        sha = first->commit->id || "";

    return ({ tag, sha || "unknown" });
}

//! Get latest tag from self-hosted git via ls-remote.
array(string) latest_tag_selfhosted(string domain, string repo_path) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    mapping result = Process.run(({"git", "ls-remote", "--tags", url}));
    if (result->exitcode != 0)
        return ({ "", "" });

    // Find latest non-^{} tag, sorted by version
    array(string) lines = filter(result->stdout / "\n",
                                 lambda(string l) {
                                     return sizeof(l) > 0 &&
                                            !has_value(l, "^{}");
                                 });
    if (sizeof(lines) == 0) return ({ "", "" });

    // Use the last line (usually highest version)
    string line = lines[-1];
    string sha = ((line / "\t")[0] || "");
    string tag = replace((line / "\t")[-1], "refs/tags/", "");
    return ({ tag, sha });
}

//! Resolve latest tag. Returns ({tag, commit_sha}).
array(string) latest_tag(string type, string domain, string repo_path) {
    switch (type) {
        case "github":     return latest_tag_github(repo_path);
        case "gitlab":     return latest_tag_gitlab(repo_path);
        case "selfhosted": return latest_tag_selfhosted(domain, repo_path);
        default: die("cannot resolve tags for source type: " + type);
    }
}

//! Resolve a specific tag to its commit SHA.
string resolve_commit_sha(string type, string domain,
                          string repo_path, string tag) {
    switch (type) {
        case "github": {
            array(int|string) result = http_get_safe(
                "https://api.github.com/repos/" + repo_path
                + "/commits/" + tag,
                github_auth_headers());
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data))
                    return data->sha || "unknown";
            }
            return "unknown";
        }
        case "gitlab": {
            string encoded = replace(repo_path, "/", "%2F");
            array(int|string) result = http_get_safe(
                "https://gitlab.com/api/v4/projects/" + encoded
                + "/repository/commits/" + tag);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data))
                    return data->id || "unknown";
            }
            return "unknown";
        }
        case "selfhosted": {
            need_cmd("git");
            mapping r = Process.run(
                ({"git", "ls-remote", "https://" + domain + "/" + repo_path,
                  "refs/tags/" + tag}));
            if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                return ((r->stdout / "\t")[0]) || "unknown";
            return "unknown";
        }
        default:
            return "unknown";
    }
}

// ── Download to store ──────────────────────────────────────────────

//! Extract a .tar.gz file to a directory.
//! Uses gunzip + Filesystem.Tar (Gz not available in all builds).
string extract_targz(string tarball_path, string dest_dir) {
    need_cmd("gunzip");

    // Decompress to temp .tar file
    string tmp_tar = String.trim_all_whites(Process.popen("mktemp /tmp/pmp_tar_XXXXXX"));
    object sout = Stdio.File(tmp_tar, "wct");
    object proc = Process.create_process(
        ({"gunzip", "-c", tarball_path}),
        (["stdout": sout]));
    sout->close();
    int exitcode = proc->wait();

    if (exitcode != 0) {
        rm(tmp_tar);
        die("gunzip failed with exit code " + exitcode);
    }

    // Extract using Filesystem.Tar
    object tar;
    mixed err = catch { tar = Filesystem.Tar(tmp_tar); };
    if (err || !tar || !sizeof(tar->tar->entries)) {
        rm(tmp_tar);
        die("failed to extract archive (not a valid tar)");
    }

    Stdio.mkdirhier(dest_dir);
    tar->tar->extract("/", dest_dir);

    // Find the top-level directory in the extracted content
    array(string) entries = get_dir(dest_dir);
    rm(tmp_tar);

    if (!entries || sizeof(entries) == 0)
        die("empty archive");

    return entries[0];
}

// Result variables from store_install_*
string res_tag;
string res_sha;
string res_hash;
string res_entry;

//! Download from GitHub to store.
void store_install_github(string repo_path, string ver) {
    string url = "https://github.com/" + repo_path
                 + "/archive/refs/tags/" + ver + ".tar.gz";

    info("downloading " + url);
    string body = http_get(url);

    // Write to temp file
    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d /tmp/pmp_install_XXXXXX"));
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    // Extract
    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    // Resolve commit SHA
    string sha = resolve_commit_sha("github", "", repo_path, ver);
    sha = sha || "unknown";

    string entry_name = store_entry_name(
        "github.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        res_tag = ver; res_sha = sha; res_hash = hash;
        res_entry = entry_name;
        return;
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    // Move extracted content to store
    string src = combine_path(tmpdir, "extract", extracted);
    Process.run(({"mv", src, entry_dir}));
    Stdio.recursive_rm(tmpdir);

    // Write .pmp-meta
    write_meta(entry_dir, "github.com/" + repo_path, ver, sha, hash);

    res_tag = ver; res_sha = sha; res_hash = hash;
    res_entry = entry_name;
    info("stored " + entry_name);
}

//! Download from GitLab to store.
void store_install_gitlab(string repo_path, string ver) {
    string repo_name = (repo_path / "/")[-1];
    string url = "https://gitlab.com/" + repo_path
                 + "/-/archive/" + ver + "/" + repo_name + "-" + ver
                 + ".tar.gz";

    info("downloading " + url);
    string body = http_get(url);

    string tmpdir = String.trim_all_whites(Process.popen("mktemp -d /tmp/pmp_install_XXXXXX"));
    string tarball = combine_path(tmpdir, "archive.tar.gz");
    Stdio.write_file(tarball, body);

    string hash = compute_sha256(tarball);

    string extracted = extract_targz(tarball,
                                     combine_path(tmpdir, "extract"));

    string sha = resolve_commit_sha("gitlab", "", repo_path, ver);
    sha = sha || "unknown";

    string entry_name = store_entry_name(
        "gitlab.com/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        res_tag = ver; res_sha = sha; res_hash = hash;
        res_entry = entry_name;
        return;
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    string src = combine_path(tmpdir, "extract", extracted);
    Process.run(({"mv", src, entry_dir}));
    Stdio.recursive_rm(tmpdir);

    write_meta(entry_dir, "gitlab.com/" + repo_path, ver, sha, hash);

    res_tag = ver; res_sha = sha; res_hash = hash;
    res_entry = entry_name;
    info("stored " + entry_name);
}

//! Clone from self-hosted git to store.
void store_install_selfhosted(string domain, string repo_path, string ver) {
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

    string sha = resolve_commit_sha("selfhosted", domain, repo_path, ver);
    sha = sha || "unknown";

    // Compute content hash from sorted file listing
    string hash = compute_dir_hash(repo_dest);

    string entry_name = store_entry_name(
        domain + "/" + repo_path, ver, sha);
    string entry_dir = combine_path(store_dir, entry_name);

    if (Stdio.is_dir(entry_dir)) {
        info("reusing existing store entry " + entry_name);
        Stdio.recursive_rm(tmpdir);
        res_tag = ver; res_sha = sha; res_hash = hash;
        res_entry = entry_name;
        return;
    }

    if (Stdio.exist(entry_dir)) rm(entry_dir);
    Stdio.mkdirhier(store_dir);
    Stdio.recursive_rm(entry_dir);
    Process.run(({"mv", repo_dest, entry_dir}));
    Stdio.recursive_rm(tmpdir);

    write_meta(entry_dir, domain + "/" + repo_path, ver, sha, hash);

    res_tag = ver; res_sha = sha; res_hash = hash;
    res_entry = entry_name;
    info("stored " + entry_name);
}

//! Write .pmp-meta file to a store entry.
void write_meta(string entry_dir, string source, string tag,
                string sha, string hash) {
    string meta = sprintf(
        "source\t%s\ntag\t%s\ncommit_sha\t%s\ncontent_sha256\t%s\ninstalled_at\t%d\n",
        source, tag, sha, hash, time());
    Stdio.write_file(combine_path(entry_dir, ".pmp-meta"), meta);
}

//! Compute a content hash from a directory by hashing sorted file contents.
string compute_dir_hash(string dir) {
    mapping result = Process.run(
        ({"find", dir, "-type", "f"}),
        (["cwd": dir]));
    if (result->exitcode != 0) return "unknown";

    array(string) files = filter(result->stdout / "\n",
                                 lambda(string f) { return sizeof(f) > 0; });
    sort(files);

    String.Buffer buf = String.Buffer();
    foreach (files; ; string f) {
        string hash = compute_sha256(combine_path(dir, f));
        buf->add(hash + "  " + f + "\n");
    }
    return String.string2hex(Crypto.SHA256.hash(buf->get()));
}

// ── Lockfile ───────────────────────────────────────────────────────

void lockfile_add_entry(string name, string source, string tag,
                        string sha, string hash) {
    lock_entries += ({ ({ name, source, tag, sha, hash }) });
}

void write_lockfile() {
    if (sizeof(lock_entries) == 0) return;

    String.Buffer buf = String.Buffer();
    buf->add("# pmp lockfile v1 — DO NOT EDIT\n");
    buf->add("# name\tsource\ttag\tcommit_sha\tcontent_sha256\n");
    foreach (lock_entries; ; array(string) entry) {
        buf->add(entry[0] + "\t" + entry[1] + "\t" + entry[2]
                 + "\t" + entry[3] + "\t" + entry[4] + "\n");
    }
    Stdio.write_file(lockfile_path, buf->get());
    info("wrote " + lockfile_path);
}

//! Read lockfile entries. Returns array of ({name, source, tag, sha, hash}).
array(array(string)) read_lockfile(void|string lf) {
    string path = lf || lockfile_path;
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

// ── Manifest helpers ───────────────────────────────────────────────

//! Add a dependency to pike.json using proper JSON round-trip.
void add_to_manifest(string name, string source) {
    if (!Stdio.exist(pike_json)) return;

    string raw = Stdio.read_file(pike_json);
    if (!raw) return;

    // Check if already present
    if (has_value(raw, "\"" + name + "\"")) return;

    mixed data;
    mixed err = catch { data = Standards.JSON.decode(raw); };
    if (err || !mappingp(data)) return;

    if (!mappingp(data->dependencies))
        data->dependencies = ([]);

    data->dependencies[name] = source;

    string encoded = Standards.JSON.encode(data,
                                           Standards.JSON.HUMAN_READABLE);
    Stdio.write_file(pike_json, encoded + "\n");
}

//! Parse dependencies from pike.json.
//! Returns array of ({name, source}).
array(array(string)) parse_deps(void|string file) {
    string path = file || pike_json;
    if (!Stdio.exist(path)) return ({});

    string raw = Stdio.read_file(path);
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

// ── Transitive dependency resolution ───────────────────────────────

//! Install a single dep from source, including transitive resolution.
void install_one(string name, string source, string target) {
    string type = detect_source_type(source);

    switch (type) {
        case "local": {
            string local_path = source;
            string project_root = find_project_root() || getcwd();
            if (has_prefix(local_path, "./"))
                local_path = combine_path(project_root, local_path);

            if (!Stdio.is_dir(local_path))
                die("local path not found: " + local_path);

            string dest = combine_path(target, name);
            Stdio.mkdirhier(target);
            // Remove existing symlink/dir if present
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(local_path, dest);
            info("linked " + name + " -> " + local_path);

            lockfile_add_entry(name, source, "-", "-", "-");
            break;
        }
        case "github":
        case "gitlab":
        case "selfhosted": {
            string ver = source_to_version(source);
            string repo_path = source_to_repo_path(source);
            string domain = source_to_domain(source);

            // Resolve version if not pinned
            if (ver == "") {
                array(string) resolved =
                    latest_tag(type, domain, repo_path);
                if (sizeof(resolved[0]) == 0)
                    die("no tags found for " + repo_path);
                ver = resolved[0];
            }

            // Check for cycle
            string visit_key = type + ":" + repo_path + "#" + ver;
            if (visited[visit_key]) {
                info("skipping already-visited " + visit_key
                     + " (cycle or duplicate)");
                return;
            }
            visited[visit_key] = 1;

            // Check if already in modules/
            string dest = combine_path(target, name);
            if (Stdio.exist(dest)) {
                // Check version
                string version_file =
                    combine_path(dest, ".version");
                if (Stdio.exist(version_file)) {
                    string existing_ver =
                        Stdio.read_file(version_file);
                    if (existing_ver == ver) {
                        info("skipping " + name + " " + ver
                             + " (already installed)");
                        string sha = "";
                        switch (type) {
                            case "github":
                            case "gitlab":
                                sha = resolve_commit_sha(
                                    type, "", repo_path, ver);
                                break;
                            case "selfhosted":
                                sha = resolve_commit_sha(
                                    type, domain, repo_path, ver);
                                break;
                        }
                        sha = sha || "unknown";
                        lockfile_add_entry(name,
                                           source_strip_version(source),
                                           ver, sha, "unknown");
                        return;
                    } else {
                        warn(name + ": version " + ver
                             + " requested but " + existing_ver
                             + " already installed — keeping existing");
                        return;
                    }
                }
            }

            info("installing " + name + " (" + ver + ") from "
                 + type + ":" + repo_path);

            // Install to store
            switch (type) {
                case "github":
                    store_install_github(repo_path, ver);
                    break;
                case "gitlab":
                    store_install_gitlab(repo_path, ver);
                    break;
                case "selfhosted":
                    store_install_selfhosted(domain, repo_path, ver);
                    break;
            }

            // Symlink from modules/ to store entry
            Stdio.mkdirhier(target);
            string entry_full = combine_path(store_dir, res_entry);
            if (Stdio.exist(dest)) rm(dest);
            System.symlink(entry_full, dest);

            // Write .version for compatibility with list command
            Stdio.write_file(combine_path(entry_full, ".version"), ver);

            info("installed " + name + " " + ver + " -> " + dest);
            lockfile_add_entry(name, source_strip_version(source),
                               res_tag, res_sha, res_hash);

            // Resolve transitive dependencies
            string pkg_json = combine_path(entry_full, "pike.json");
            if (Stdio.exist(pkg_json)) {
                array(array(string)) trans_deps =
                    parse_deps(pkg_json);
                foreach (trans_deps; ; array(string) dep) {
                    info("  transitive: " + dep[0] + " from " + dep[1]);
                    install_one(dep[0], dep[1], target);
                }
            }
            break;
        }
    }
}

// ── Manifest validation (warn-only) ────────────────────────────────

multiset(string) std_libs = (<
    "Stdio", "Array", "Mapping", "Multiset", "String", "System",
    "Thread", "__builtin", "crypto", "Image", "Protocols", "Yp",
    "ADT", "Cache", "Calendar", "Colors", "Crypto", "Geographic",
    "GL", "Graphics", "GTK", "Java", "Locale", "MIME", "Math",
    "Media", "Module", "Parser", "Pike", "Pikefonts", "Process",
    "SSL", "Support", "Types", "Web", "X"
>);

void validate_manifests() {
    if (!Stdio.is_dir(local_dir)) return;
    info("validating imports against declared dependencies...");

    foreach (get_dir(local_dir); ; string mod_name) {
        string moddir = combine_path(local_dir, mod_name);
        if (!Stdio.is_dir(moddir)) continue;

        // Resolve real path through symlink
        string real_dir = moddir;
        mixed err = catch {
            real_dir = System.readlink(moddir) || moddir;
        };

        // Collect imports from .pike and .pmod files
        multiset(string) imports = (<>);
        void collect_imports(string dir) {
            if (!Stdio.is_dir(dir)) return;
            foreach (get_dir(dir) || ({}); ; string entry) {
                string full = combine_path(dir, entry);
                if (Stdio.is_dir(full) &&
                    has_suffix(entry, ".pmod")) {
                    collect_imports(full);
                }
                if (has_suffix(entry, ".pike") ||
                    has_suffix(entry, ".pmod")) {
                    string content = Stdio.read_file(full);
                    if (!content) continue;
                    // Match import Foo patterns
                    foreach (content / "\n"; ; string line) {
                        array matches =
                            Regexp("import[ \t]+([A-Za-z_][A-Za-z0-9_]*)")
                            ->split(line);
                        if (matches && sizeof(matches) > 0)
                            imports[matches[0]] = 1;
                    }
                }
            }
        };
        collect_imports(real_dir);

        // Get declared deps
        string pkg_json = combine_path(real_dir, "pike.json");
        multiset(string) declared = (<>);
        if (Stdio.exist(pkg_json)) {
            foreach (parse_deps(pkg_json); ; array(string) dep)
                declared[dep[0]] = 1;
        }

        // Check each import
        foreach (indices(imports); ; string imp) {
            if (imp == mod_name) continue;
            if (std_libs[imp]) continue;
            if (!declared[imp])
                warn(mod_name + " imports " + imp
                     + " but does not declare it as a dependency");
        }
    }
}

// ── Commands ───────────────────────────────────────────────────────

void cmd_version() {
    info("pmp v" + PMP_VERSION);
}

void cmd_init() {
    if (Stdio.exist(pike_json))
        die("pike.json already exists in this directory");

    string content = "{\n  \"dependencies\": {}\n}\n";
    Stdio.write_file(pike_json, content);
    info("created pike.json");
}

void cmd_install(array(string) args) {
    int global_flag = 0;
    string source = "";

    foreach (args; ; string arg) {
        if (arg == "-g") global_flag = 1;
        else source = arg;
    }

    string target;
    if (global_flag)
        target = global_dir;
    else
        target = local_dir;

    if (source == "") {
        if (!Stdio.exist(pike_json))
            die("no pike.json found in current directory");
        cmd_install_all(target);
    } else {
        visited = (<>);
        lock_entries = ({});
        cmd_install_source(source, target);
        if (!global_flag) {
            write_lockfile();
            if (Stdio.exist(pike_json)) {
                string name = source_to_name(source);
                string clean_source = source_strip_version(source);
                add_to_manifest(name, clean_source);
            }
            validate_manifests();
        }
    }
}

void cmd_install_all(string target) {
    visited = (<>);
    lock_entries = ({});

    // Check if lockfile exists and covers all deps
    int use_lockfile = 0;
    if (Stdio.exist(lockfile_path) && target == local_dir) {
        use_lockfile = 1;
        int lockfile_complete = 1;

        array(array(string)) deps = parse_deps();
        foreach (deps; ; array(string) dep) {
            if (!lockfile_has_dep(dep[0])) {
                lockfile_complete = 0;
                break;
            }
        }

        if (lockfile_complete) {
            info("installing from " + lockfile_path + " (up to date)");
            array(array(string)) lf_entries = read_lockfile();
            foreach (lf_entries; ; array(string) entry) {
                string ln = entry[0], ls = entry[1],
                       lt = entry[2], lsha = entry[3],
                       lhash = entry[4];
                if (sizeof(ln) == 0) continue;

                if (ls == "-" || has_prefix(ls, "./")
                    || has_prefix(ls, "/")) {
                    // Local dep — just symlink
                    if (sizeof(ls) > 0 && ls != "-") {
                        string local_path = ls;
                        string project_root =
                            find_project_root() || getcwd();
                        if (has_prefix(local_path, "./"))
                            local_path =
                                combine_path(project_root, local_path);

                        if (!Stdio.is_dir(local_path)) {
                            warn("local dep " + ln + " path "
                                 + local_path + " not found");
                            continue;
                        }
                        Stdio.mkdirhier(target);
                        string dest = combine_path(target, ln);
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(local_path, dest);
                        info("linked " + ln + " -> " + local_path);
                    }
                } else {
                    // Remote dep — find store entry
                    string slug = replace(ls, "/", "-");
                    string pattern = slug + "-" + lt + "-*";
                    string found_entry = "";

                    if (Stdio.is_dir(store_dir)) {
                        foreach (get_dir(store_dir) || ({}); ;
                                 string se) {
                            if (glob(pattern, se) &&
                                Stdio.is_dir(
                                    combine_path(store_dir, se))) {
                                found_entry = se;
                                break;
                            }
                        }
                    }

                    if (sizeof(found_entry) > 0) {
                        Stdio.mkdirhier(target);
                        string dest = combine_path(target, ln);
                        if (Stdio.exist(dest)) rm(dest);
                        System.symlink(
                            combine_path(store_dir, found_entry),
                            dest);
                        info("installed " + ln + " " + lt
                             + " (from lockfile)");
                    } else {
                        info("lockfile entry for " + ln
                             + " not in store — re-resolving");
                        use_lockfile = 0;
                    }
                }
                lockfile_add_entry(ln, ls, lt, lsha, lhash);
            }
        } else {
            info("lockfile is stale — re-resolving missing deps");
            use_lockfile = 0;
        }
    }

    if (!use_lockfile) {
        info("installing dependencies from pike.json...");
        array(array(string)) deps = parse_deps();
        foreach (deps; ; array(string) dep)
            install_one(dep[0], dep[1], target);
    }

    if (target == local_dir) {
        write_lockfile();
        validate_manifests();
    }

    info("done");
}

void cmd_install_source(string source, string target) {
    string name = source_to_name(source);
    visited = (<>);
    install_one(name, source, target);
}

void cmd_update(array(string) args) {
    string mod_name = sizeof(args) > 0 ? args[0] : "";

    // Remove lockfile to force fresh resolution
    if (Stdio.exist(lockfile_path)) rm(lockfile_path);

    if (sizeof(mod_name) > 0) {
        info("updating " + mod_name + "...");
        string src = "";
        array(array(string)) deps = parse_deps();
        foreach (deps; ; array(string) dep) {
            if (dep[0] == mod_name) { src = dep[1]; break; }
        }
        if (sizeof(src) == 0)
            die("module " + mod_name + " not found in pike.json");
        visited = (<>);
        lock_entries = ({});
        install_one(mod_name, src, local_dir);
        write_lockfile();
    } else {
        if (!Stdio.exist(pike_json))
            die("no pike.json found");
        cmd_install_all(local_dir);
    }
}

void cmd_lock() {
    if (!Stdio.exist(pike_json))
        die("no pike.json found");
    visited = (<>);
    lock_entries = ({});

    info("resolving dependencies...");
    array(array(string)) deps = parse_deps();
    foreach (deps; ; array(string) dep)
        install_one(dep[0], dep[1], local_dir);

    write_lockfile();
    info("lockfile written");
}

void cmd_store(array(string) args) {
    string subcmd = sizeof(args) > 0 ? args[0] : "";

    switch (subcmd) {
        case "prune": {
            if (!Stdio.is_dir(store_dir)) {
                info("no store directory");
                return;
            }
            int pruned = 0;
            foreach (get_dir(store_dir) || ({}); ; string ename) {
                string entry = combine_path(store_dir, ename);
                if (!Stdio.is_dir(entry)) continue;

                if (Stdio.is_dir(local_dir)) {
                    int found = 0;
                    foreach (get_dir(local_dir) || ({}); ;
                             string lname) {
                        string link = combine_path(local_dir, lname);
                        mixed err = catch {
                            string target = System.readlink(link);
                            if (target && has_value(target, ename)) {
                                found = 1;
                                break;
                            }
                        };
                    }
                    if (!found) {
                        // Not linked from this project —
                        // but could be from others
                        info("unused store entry: " + ename);
                        pruned = 1;
                    }
                }
            }
            if (!pruned) info("no unused entries found");
            break;
        }
        case "": {
            // Show store status
            if (!Stdio.is_dir(store_dir)) {
                info("store is empty (" + store_dir + ")");
                return;
            }
            int count = 0;
            foreach (get_dir(store_dir) || ({}); ; string ename) {
                string entry = combine_path(store_dir, ename);
                if (!Stdio.is_dir(entry)) continue;

                string tag = "";
                string meta_file =
                    combine_path(entry, ".pmp-meta");
                if (Stdio.exist(meta_file)) {
                    string meta = Stdio.read_file(meta_file);
                    foreach (meta / "\n"; ; string line) {
                        if (has_prefix(line, "tag\t"))
                            tag = line[4..];
                    }
                }

                // Get size using du
                mapping r = Process.run(
                    ({"du", "-sh", entry}));
                string esize = "";
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    esize = (r->stdout / "\t")[0];

                write(sprintf("  %-55s %s\n", ename, esize));
                count++;
            }
            // Total size
            mapping r = Process.run(({"du", "-sh", store_dir}));
            string total = "";
            if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                total = (r->stdout / "\t")[0];
            write(sprintf("\n  %d entries, %s total\n", count, total));
            break;
        }
        default:
            die("unknown store subcommand: " + subcmd);
    }
}

void cmd_list(array(string) args) {
    string dir = local_dir;
    if (sizeof(args) > 0 && args[0] == "-g")
        dir = global_dir;

    if (!Stdio.is_dir(dir)) {
        info("no modules installed");
        return;
    }

    int found = 0;
    foreach (get_dir(dir) || ({}); ; string mod_name) {
        string moddir = combine_path(dir, mod_name);
        if (!Stdio.is_dir(moddir)) continue;

        string ver = "(unknown)";
        string ver_file = combine_path(moddir, ".version");
        if (Stdio.exist(ver_file))
            ver = Stdio.read_file(ver_file) || "(unknown)";

        string src = "";
        mixed err = catch {
            string link = System.readlink(moddir);
            if (link && has_prefix(link, store_dir)) {
                src = " (store: " + (link / "/")[-1] + ")";
            } else if (link) {
                src = " -> " + link;
            }
        };

        write(sprintf("  %-20s %-12s%s\n", mod_name, ver, src));
        found = 1;
    }

    if (!found) info("no modules installed");
}

void cmd_clean() {
    if (Stdio.is_dir(local_dir)) {
        Stdio.recursive_rm(local_dir);
        info("removed " + local_dir + " (store preserved)");
    } else {
        info("nothing to clean");
    }
}

//! Build module + include paths from project root and global dir.
array(array(string)) build_paths() {
    array(string) mod_paths = ({});
    array(string) inc_paths = ({});

    string project_root = find_project_root() || getcwd();
    string pr_modules = combine_path(project_root, "modules");
    if (Stdio.is_dir(pr_modules)) {
        mod_paths += ({ pr_modules });
        // Check for .h files
        mapping r = Process.run(
            ({"find", pr_modules, "-name", "*.h", "-print", "-quit"}));
        if (r->exitcode == 0 && sizeof(r->stdout) > 0)
            inc_paths += ({ pr_modules });
    }

    // Local deps from pike.json
    string pjson = combine_path(project_root, "pike.json");
    if (Stdio.exist(pjson)) {
        foreach (parse_deps(pjson); ; array(string) dep) {
            if (has_prefix(dep[1], "./") || has_prefix(dep[1], "/")) {
                string lpath = dep[1];
                if (has_prefix(lpath, "./"))
                    lpath = combine_path(project_root, lpath);
                if (!Stdio.is_dir(lpath)) continue;
                mod_paths += ({ lpath });
                mapping r = Process.run(
                    ({"find", lpath, "-name", "*.h",
                      "-print", "-quit"}));
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    inc_paths += ({ lpath });
            }
        }
    }

    if (Stdio.is_dir(global_dir)) {
        mod_paths += ({ global_dir });
        mapping r = Process.run(
            ({"find", global_dir, "-name", "*.h",
              "-print", "-quit"}));
        if (r->exitcode == 0 && sizeof(r->stdout) > 0)
            inc_paths += ({ global_dir });
    }

    return ({ mod_paths, inc_paths });
}

void cmd_remove(array(string) args) {
    if (sizeof(args) == 0)
        die("usage: pmp remove <name>");
    string name = args[0];

    // Remove from pike.json
    if (Stdio.exist(pike_json)) {
        string raw = Stdio.read_file(pike_json);
        if (raw) {
            mixed data;
            mixed err = catch { data = Standards.JSON.decode(raw); };
            if (!err && mappingp(data) && mappingp(data->dependencies)) {
                if (!zero_type(data->dependencies[name])) {
                    m_delete(data->dependencies, name);
                    Stdio.write_file(pike_json,
                        Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");
                    info("removed " + name + " from pike.json");
                }
            }
        }
    }

    // Remove symlink
    string link = combine_path(local_dir, name);
    if (Stdio.exist(link)) {
        rm(link);
        info("removed " + link);
    }

    // Update lockfile
    if (Stdio.exist(lockfile_path)) {
        array(array(string)) entries = read_lockfile();
        array(array(string)) new_entries = ({});
        foreach (entries; ; array(string) e)
            if (e[0] != name) new_entries += ({ e });
        lock_entries = new_entries;
        write_lockfile();
    }
}

void cmd_run(array(string) args) {
    if (sizeof(args) == 0)
        die("usage: pmp run <script.pike> [args...]");

    string script = args[0];
    array(string) script_args = args[1..];

    array(array(string)) paths = build_paths();
    array(string) mod_paths = paths[0];
    array(string) inc_paths = paths[1];

    array(string) env_vars = ({});
    if (sizeof(mod_paths) > 0) {
        string existing = getenv("PIKE_MODULE_PATH") || "";
        string new_path = mod_paths * ":";
        if (sizeof(existing) > 0) new_path += ":" + existing;
        env_vars += ({"PIKE_MODULE_PATH=" + new_path});
    }
    if (sizeof(inc_paths) > 0) {
        string existing = getenv("PIKE_INCLUDE_PATH") || "";
        string new_path = inc_paths * ":";
        if (sizeof(existing) > 0) new_path += ":" + existing;
        env_vars += ({"PIKE_INCLUDE_PATH=" + new_path});
    }

    if (sizeof(env_vars) > 0) {
        // Build environment map from current env + overrides
        mapping(string:string) env = getenv() || ([]);
        foreach (env_vars; ; string var) {
            array parts = var / "=";
            if (sizeof(parts) >= 2)
                env[parts[0]] = parts[1..] * "=";
        }
        Process.exece(pike_bin,
            ({ pike_bin, script, @script_args }), env);
    } else {
        Process.exec(pike_bin, script, @script_args);
    }
}

// ── Environment ────────────────────────────────────────────────────

void cmd_env() {
    string env_dir = ".pike-env";
    string env_bin = combine_path(env_dir, "bin");

    if (Stdio.is_dir(env_dir))
        info(".pike-env/ already exists — recreating bin/pike wrapper");

    Stdio.mkdirhier(env_bin);

    string project_root = find_project_root() || getcwd();

    // Resolve local dep paths from pike.json at generation time
    array(string) local_mod_paths = ({});
    array(string) local_inc_paths = ({});
    string pjson = combine_path(project_root, "pike.json");
    if (Stdio.exist(pjson)) {
        foreach (parse_deps(pjson); ; array(string) dep) {
            if (has_prefix(dep[1], "./") || has_prefix(dep[1], "/")) {
                string lpath = dep[1];
                if (has_prefix(lpath, "./"))
                    lpath = combine_path(project_root, lpath);
                if (!Stdio.is_dir(lpath)) continue;
                local_mod_paths += ({ lpath });
                mapping r = Process.run(
                    ({"find", lpath, "-name", "*.h",
                      "-print", "-quit"}));
                if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                    local_inc_paths += ({ lpath });
            }
        }
    }

    // Build local dep path entries for the wrapper
    string local_mod_block = "";
    foreach (local_mod_paths; ; string p)
        local_mod_block += "  MOD_PATHS=\"${MOD_PATHS:+$MOD_PATHS:}" + p + "\"\n";
    string local_inc_block = "";
    foreach (local_inc_paths; ; string p)
        local_inc_block += "  INC_PATHS=\"${INC_PATHS:+$INC_PATHS:}" + p + "\"\n";

    // Build the pike wrapper as a shell script
    // Uses string concatenation instead of sprintf to avoid %s conflicts
    // in the embedded Pike -e code
    string wrapper =
        "#!/bin/sh\n"
        "# Generated by pmp env. Re-run 'pmp env' to update.\n"
        "PROJECT_ROOT=\"" + project_root + "\"\n"
        "PIKE_BIN=\"" + pike_bin + "\"\n"
        "GLOBAL_DIR=\"$HOME/.pike/modules\"\n"
        "\n"
        "MOD_PATHS=\"\"\n"
        "INC_PATHS=\"\"\n"
        "\n"
        "# Project modules\n"
        "if [ -d \"$PROJECT_ROOT/modules\" ]; then\n"
        "  MOD_PATHS=\"$PROJECT_ROOT/modules\"\n"
        "  if find \"$PROJECT_ROOT/modules\" -name '*.h' -print -quit 2>/dev/null | grep -q .; then\n"
        "    INC_PATHS=\"$PROJECT_ROOT/modules\"\n"
        "  fi\n"
        "fi\n"
        "\n";

    // Inject local dep paths (resolved at generation time)
    if (sizeof(local_mod_paths) > 0)
        wrapper += "# Local dependencies (resolved from pike.json)\n"
            + local_mod_block
            + local_inc_block
            + "\n";

    wrapper +=
        "# Global modules\n"
        "if [ -d \"$GLOBAL_DIR\" ]; then\n"
        "  MOD_PATHS=\"${MOD_PATHS:+$MOD_PATHS:}$GLOBAL_DIR\"\n"
        "fi\n"
        "\n"
        "# Build environment and exec real Pike\n"
        "_env=\"\"\n"
        "if [ -n \"$MOD_PATHS\" ]; then\n"
        "  _env=\"PIKE_MODULE_PATH=$MOD_PATHS${PIKE_MODULE_PATH+:$PIKE_MODULE_PATH}\"\n"
        "fi\n"
        "if [ -n \"$INC_PATHS\" ]; then\n"
        "  _env=\"${_env:+$_env }PIKE_INCLUDE_PATH=$INC_PATHS${PIKE_INCLUDE_PATH+:$PIKE_INCLUDE_PATH}\"\n"
        "fi\n"
        "\n"
        "if [ -n \"$_env\" ]; then\n"
        "  exec env $_env \"$PIKE_BIN\" \"$@\"\n"
        "else\n"
        "  exec \"$PIKE_BIN\" \"$@\"\n"
        "fi\n";

    Stdio.write_file(combine_path(env_bin, "pike"), wrapper);
    Process.run(({"chmod", "+x", combine_path(env_bin, "pike")}));

    // Create activate script
    string abs_env_dir = combine_path(getcwd(), env_dir);
    string activate = sprintf(
        "# pmp environment activation. "
        "Source this: . .pike-env/activate\n"
        "\n"
        "# Env directory is baked in at creation time\n"
        "_pike_env_dir=\"%s\"\n"
        "_pike_env_bin=\"$_pike_env_dir/bin\"\n"
        "\n"
        "# Save original PATH\n"
        "if [ -z \"$_pike_env_old_path\" ]; then\n"
        "  _pike_env_old_path=\"$PATH\"\n"
        "fi\n"
        "\n"
        "# Prepend env bin to PATH\n"
        "PATH=\"$_pike_env_bin:$PATH\"\n"
        "export PATH\n"
        "\n"
        "# Marker for detection\n"
        "PIKE_ENV_PATH=\"$_pike_env_dir\"\n"
        "export PIKE_ENV_PATH\n"
        "\n"
        "pmp_deactivate() {\n"
        "  if [ -n \"$_pike_env_old_path\" ]; then\n"
        "    PATH=\"$_pike_env_old_path\"\n"
        "    export PATH\n"
        "    unset _pike_env_old_path\n"
        "  fi\n"
        "  unset PIKE_ENV_PATH\n"
        "  if [ -n \"$_pike_env_old_ps1\" ]; then\n"
        "    PS1=\"$_pike_env_old_ps1\"\n"
        "    unset _pike_env_old_ps1\n"
        "  fi\n"
        "  unset -f pmp_deactivate\n"
        "}\n"
        "\n"
        "# Shell prompt indicator\n"
        "if [ -z \"$_pike_env_old_ps1\" ]; then\n"
        "  _pike_env_old_ps1=\"$PS1\"\n"
        "  PS1=\"(pike) $PS1\"\n"
        "fi\n",
        abs_env_dir);

    Stdio.write_file(combine_path(env_dir, "activate"), activate);

    info("created .pike-env/");
    info("  activate with:  . .pike-env/activate");
    info("  or use directly: .pike-env/bin/pike");
}

// ── Main ───────────────────────────────────────────────────────────

void print_help() {
    write("pmp — Pike Module Package Manager\n\n");
    write("Usage:\n");
    write("  pmp init                                    "
          "Create pike.json\n");
    write("  pmp install                                 "
          "Install all deps (from lockfile or pike.json)\n");
    write("  pmp install <url>                           "
          "Add and install dependency\n");
    write("  pmp install <url>#tag                       "
          "Install specific version\n");
    write("  pmp install ./local/path                    "
          "Local dependency (symlinked)\n");
    write("  pmp install -g <url>                        "
          "Install system-wide\n");
    write("  pmp update [module]                         "
          "Update deps to latest tags\n");
    write("  pmp lock                                    "
          "Write pike.lock\n");
    write("  pmp store                                   "
          "Show store entries and disk usage\n");
    write("  pmp store prune                             "
          "Show unused store entries\n");
    write("  pmp list [-g]                               "
          "Show installed dependencies\n");
    write("  pmp env                                     "
          "Create .pike-env/ virtual environment\n");
    write("  pmp clean                                   "
          "Remove ./modules/ (keeps store)\n");
    write("  pmp remove <name>                         "
          "Remove a dependency\n");
    write("  pmp run <script>                            "
          "Run script with module paths\n");
    write("  pmp version                                 "
          "Show version\n");
    write("\nSource formats:\n");
    write("  github.com/owner/repo                       "
          "GitHub\n");
    write("  gitlab.com/owner/repo                       "
          "GitLab\n");
    write("  git.example.com/owner/repo                  "
          "Self-hosted git\n");
    write("  ./local/path or /abs/path                   "
          "Local module\n");
}

int main(int argc, array(string) argv) {
    // Configuration
    array(string) search_path = (getenv("PATH") || "/usr/bin:/bin") / ":";
    pike_bin = getenv("PIKE_BIN")
        || Process.locate_binary(search_path, "pike8.0")
        || Process.locate_binary(search_path, "pike")
        || "/usr/local/pike/8.0.1116/bin/pike";
    global_dir = combine_path(getenv("HOME") || "/tmp", ".pike/modules");
    store_dir = combine_path(getenv("HOME") || "/tmp", ".pike/store");

    if (argc < 2) {
        print_help();
        return 0;
    }

    string cmd = argv[1];
    array(string) args = argv[2..];

    switch (cmd) {
        case "init":     cmd_init(); break;
        case "install":  cmd_install(args); break;
        case "update":   cmd_update(args); break;
        case "lock":     cmd_lock(); break;
        case "store":    cmd_store(args); break;
        case "list":     cmd_list(args); break;
        case "clean":    cmd_clean(); break;
        case "remove":   cmd_remove(args); break;
        case "run":      cmd_run(args); break;
        case "env":      cmd_env(); break;
        case "version":  cmd_version(); break;
        case "-h":
        case "--help":
            print_help();
            break;
        default:
            die("unknown command '" + cmd + "' (try: pmp --help)");
    }
    return 0;
}

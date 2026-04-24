//! URL-encode a string for use in API path segments.
//! Uses Protocols.HTTP.percent_encode for full RFC 2396 coverage.
private string _encode_tag(string tag) {
    return Protocols.HTTP.percent_encode(tag);
}

inherit .Helpers;
inherit .Http;
inherit .Semver;

//! Get latest tag from GitHub — returns highest semver, not most-recently-created.
//! Paginates through all tags (GitHub caps at 100 per page).
array(string) latest_tag_github(string repo_path, void|string version) {
    array(string) tag_names = ({});
    array(mapping) all_entries = ({});

    // Paginate through all tags
    int page = 1;
    while (1) {
        string url = "https://api.github.com/repos/" + repo_path
                     + "/tags?per_page=100&page=" + page;
        string body = http_get(url, github_auth_headers(), version);

        mixed data;
        mixed err = catch { data = Standards.JSON.decode(body); };
        if (err || !arrayp(data) || sizeof(data) == 0)
            break;  // No more pages or error

        array(mapping) valid = filter(data, lambda(mapping e) { return !!e->name; });
        tag_names += column(valid, "name");
        all_entries += valid;

        if (sizeof(data) < 100)
            break;  // Last page
        page++;
    }

    if (sizeof(tag_names) == 0)
        return ({ "", "" });

    tag_names = sort_tags_semver(tag_names);
    if (sizeof(tag_names) == 0)
        return ({ "", "" });

    string tag = tag_names[0];

    mapping(string:mapping) by_name = mkmapping(column(all_entries, "name"), all_entries);
    string sha = "";
    if (by_name[tag] && mappingp(by_name[tag]->commit))
        sha = by_name[tag]->commit->sha || "";

    if (sha == "") {
        // Fallback: fetch commit SHA from the ref endpoint
        array(int|string) result = http_get_safe(
            "https://api.github.com/repos/" + repo_path + "/commits/" + _encode_tag(tag),
            github_auth_headers(), version);
            if (result[0] == 200) {
                mixed commit_data;
                mixed fallback_err = catch { commit_data = Standards.JSON.decode(result[1]); };
                if (!fallback_err && mappingp(commit_data))
                    sha = commit_data->sha || "";
            }
    }
    return ({ tag, sha || "" });
}

//! Get latest tag from GitLab — returns highest semver, not most-recently-created.
//! Paginates through all tags (GitLab caps at 100 per page).
array(string) latest_tag_gitlab(string repo_path, void|string version) {
    string encoded = Protocols.HTTP.percent_encode(repo_path);
    array(string) tag_names = ({});
    array(mapping) all_entries = ({});

    // Paginate through all tags
    int page = 1;
    while (1) {
        string url = "https://gitlab.com/api/v4/projects/"
                     + encoded + "/repository/tags?per_page=100&page=" + page;
        string body = http_get(url, 0, version);

        mixed data;
        mixed err = catch { data = Standards.JSON.decode(body); };
        if (err || !arrayp(data) || sizeof(data) == 0)
            break;

        array(mapping) valid = filter(data, lambda(mapping e) { return !!e->name; });
        tag_names += column(valid, "name");
        all_entries += valid;

        if (sizeof(data) < 100)
            break;
        page++;
    }

    if (sizeof(tag_names) == 0)
        return ({ "", "" });

    tag_names = sort_tags_semver(tag_names);
    if (sizeof(tag_names) == 0)
        return ({ "", "" });

    string tag = tag_names[0];

    mapping(string:mapping) by_name = mkmapping(column(all_entries, "name"), all_entries);
    string sha = "";
    if (by_name[tag] && mappingp(by_name[tag]->commit))
        sha = by_name[tag]->commit->id || "";

    return ({ tag, sha || "" });
}

//! Get latest tag from self-hosted git via ls-remote.
//! Uses --sort=-v:refname then applies semver sort on top.
array(string) latest_tag_selfhosted(string domain, string repo_path) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    // SSRF protection — validate domain before git ls-remote
    if (_is_private_host(domain))
        die("blocked: SSRF protection — refusing to ls-remote from private/internal address: " + domain);

    mapping result = Process.run(({"git", "ls-remote", "--sort=-v:refname", "--tags", url}));
    if (result->exitcode != 0)
        return ({ "", "" });

    // Parse all lines, collect tag->sha pairs (prefer peeled ^{} SHA)
    mapping(string:string) peeled = ([]);  // tag -> peeled SHA
    mapping(string:string) unpeeled = ([]); // tag -> tag object SHA
    foreach (result->stdout / "\n"; ; string line) {
        if (sizeof(line) == 0) continue;
        array(string) parts = line / "\t";
        if (sizeof(parts) >= 2) {
            string ref = parts[1];
            string tag = replace(ref, "refs/tags/", "");
            if (has_suffix(ref, "^{}")) {
                tag = replace(tag, "^{}", "");
                peeled[tag] = parts[0];
            } else {
                unpeeled[tag] = parts[0];
            }
        }
    }

    // Merge: prefer peeled SHA, fall back to unpeeled
    array(string) tag_names = sort_tags_semver(indices(unpeeled) | indices(peeled));
    if (sizeof(tag_names) == 0) return ({ "", "" });

    string best = tag_names[0];
    string sha = peeled[best] || unpeeled[best] || "";
    return ({ best, sha });
}

//! Resolve latest tag. Returns ({tag, commit_sha}).
array(string) latest_tag(string type, string domain, string repo_path,
                         void|string version) {
    switch (type) {
        case "github":     return latest_tag_github(repo_path, version);
        case "gitlab":     return latest_tag_gitlab(repo_path, version);
        case "selfhosted": return latest_tag_selfhosted(domain, repo_path);
        default: die("cannot resolve tags for source type: " + type, EXIT_INTERNAL);
    }
}

//! Non-dying variant of latest_tag_github for batch operations.
//! Uses http_get_safe so HTTP errors return ({"",""}) instead of killing the process.
array(string) latest_tag_github_safe(string repo_path, void|string version) {
    array(string) tag_names = ({});
    array(mapping) all_entries = ({});

    int page = 1;
    while (1) {
        string url = "https://api.github.com/repos/" + repo_path
                     + "/tags?per_page=100&page=" + page;
        array(int|string) result = http_get_safe(url, github_auth_headers(), version);
        if (result[0] != 200) break;

        mixed data;
        mixed err = catch { data = Standards.JSON.decode(result[1]); };
        if (err || !arrayp(data) || sizeof(data) == 0) break;

        array(mapping) valid = filter(data, lambda(mapping e) { return !!e->name; });
        tag_names += column(valid, "name");
        all_entries += valid;

        if (sizeof(data) < 100) break;
        page++;
    }

    if (sizeof(tag_names) == 0) return ({ "", "" });
    tag_names = sort_tags_semver(tag_names);
    if (sizeof(tag_names) == 0) return ({ "", "" });

    string tag = tag_names[0];

    mapping(string:mapping) by_name = mkmapping(column(all_entries, "name"), all_entries);
    string sha = "";
    if (by_name[tag] && mappingp(by_name[tag]->commit))
        sha = by_name[tag]->commit->sha || "";

    if (sha == "") {
        array(int|string) sha_result = http_get_safe(
            "https://api.github.com/repos/" + repo_path + "/commits/" + _encode_tag(tag),
            github_auth_headers(), version);
        if (sha_result[0] == 200) {
            mixed commit_data;
            mixed fallback_err = catch { commit_data = Standards.JSON.decode(sha_result[1]); };
            if (!fallback_err && mappingp(commit_data))
                sha = commit_data->sha || "";
        }
    }
    return ({ tag, sha || "" });
}

//! Non-dying variant of latest_tag_gitlab for batch operations.
//! Uses http_get_safe so HTTP errors return ({"",""}) instead of killing the process.
array(string) latest_tag_gitlab_safe(string repo_path, void|string version) {
    string encoded = Protocols.HTTP.percent_encode(repo_path);
    array(string) tag_names = ({});
    array(mapping) all_entries = ({});

    int page = 1;
    while (1) {
        string url = "https://gitlab.com/api/v4/projects/"
                     + encoded + "/repository/tags?per_page=100&page=" + page;
        array(int|string) result = http_get_safe(url, 0, version);
        if (result[0] != 200) break;

        mixed data;
        mixed err = catch { data = Standards.JSON.decode(result[1]); };
        if (err || !arrayp(data) || sizeof(data) == 0) break;

        array(mapping) valid = filter(data, lambda(mapping e) { return !!e->name; });
        tag_names += column(valid, "name");
        all_entries += valid;

        if (sizeof(data) < 100) break;
        page++;
    }

    if (sizeof(tag_names) == 0) return ({ "", "" });
    tag_names = sort_tags_semver(tag_names);
    if (sizeof(tag_names) == 0) return ({ "", "" });

    string tag = tag_names[0];

    mapping(string:mapping) by_name = mkmapping(column(all_entries, "name"), all_entries);
    string sha = "";
    if (by_name[tag] && mappingp(by_name[tag]->commit))
        sha = by_name[tag]->commit->id || "";

    return ({ tag, sha || "" });
}

//! Non-dying tag resolution for batch operations like cmd_outdated.
//! Returns ({"", ""}) on any failure instead of terminating the process.
array(string) latest_tag_safe(string type, string domain, string repo_path,
                               void|string version) {
    switch (type) {
    case "github":
        return latest_tag_github_safe(repo_path, version);
    case "gitlab":
        return latest_tag_gitlab_safe(repo_path, version);
    case "selfhosted": {
        mixed err = catch {
            return latest_tag_selfhosted(domain, repo_path);
        };
        return ({ "", "" });
    }
    default:
        return ({ "", "" });
    }
}

//! Resolve a specific tag to its commit SHA.
//! Returns 0 if the SHA cannot be resolved.
string resolve_commit_sha(string type, string domain,
                          string repo_path, string tag,
                          void|string version) {
    switch (type) {
        case "github": {
            array(int|string) result = http_get_safe(
                "https://api.github.com/repos/" + repo_path
                + "/commits/" + _encode_tag(tag),
                github_auth_headers(), version);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data))
                    return data->sha;
            }
            return 0;
        }
        case "gitlab": {
            string encoded = Protocols.HTTP.percent_encode(repo_path);
            array(int|string) result = http_get_safe(
                "https://gitlab.com/api/v4/projects/" + encoded
                + "/repository/commits/" + _encode_tag(tag), 0, version);
            if (result[0] == 200) {
                mixed data;
                mixed err = catch { data = Standards.JSON.decode(result[1]); };
                if (!err && mappingp(data))
                    return data->id;
            }
            return 0;
        }
        case "selfhosted": {
            need_cmd("git");
            // SSRF protection — validate domain before git ls-remote
            if (_is_private_host(domain))
                die("blocked: SSRF protection — refusing to ls-remote from private/internal address: " + domain);

            mapping r = Process.run(
                ({"git", "ls-remote", "https://" + domain + "/" + repo_path,
                  "refs/tags/" + tag}));
            if (r->exitcode == 0 && sizeof(r->stdout) > 0) {
                string sha;
                foreach (r->stdout / "\n"; ; string line) {
                    if (sizeof(line) == 0) continue;
                    array parts = line / "\t";
                    if (sizeof(parts) >= 2 && has_suffix(parts[1], "^{}")) {
                        sha = parts[0];
                    } else if (!sha && sizeof(parts) >= 2) {
                        sha = parts[0];
                    }
                }
                if (sha) return sha;
            }
            return 0;
        }
        default:
            die("unknown source type: " + type, EXIT_INTERNAL);
    }
}

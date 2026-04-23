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

        foreach (data; ; mapping entry)
            if (entry->name) {
                tag_names += ({ entry->name });
                all_entries += ({ entry });
            }

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

    // Find the entry for this tag to get its SHA
    string sha = "";
    foreach (all_entries; ; mapping entry) {
        if (entry->name == tag) {
            if (mappingp(entry->commit))
                sha = entry->commit->sha || "";
            break;
        }
    }

    if (sha == "") {
        // Fallback: fetch commit SHA from the ref endpoint
        array(int|string) result = http_get_safe(
            "https://api.github.com/repos/" + repo_path + "/commits/" + tag,
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
    string encoded = replace(repo_path, "/", "%2F");
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

        foreach (data; ; mapping entry)
            if (entry->name) {
                tag_names += ({ entry->name });
                all_entries += ({ entry });
            }

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

    // Find the entry for this tag to get its SHA
    string sha = "";
    foreach (all_entries; ; mapping entry) {
        if (entry->name == tag) {
            if (mappingp(entry->commit))
                sha = entry->commit->id || "";
            break;
        }
    }

    return ({ tag, sha || "" });
}

//! Get latest tag from self-hosted git via ls-remote.
//! Uses --sort=-v:refname then applies semver sort on top.
array(string) latest_tag_selfhosted(string domain, string repo_path) {
    need_cmd("git");
    string url = "https://" + domain + "/" + repo_path;

    mapping result = Process.run(({"git", "ls-remote", "--sort=-v:refname", "--tags", url}));
    if (result->exitcode != 0)
        return ({ "", "" });

    // Collect non-^{} tag lines
    array(string) lines = filter(result->stdout / "\n",
                                 lambda(string l) {
                                     return sizeof(l) > 0 &&
                                            !has_value(l, "^{}");
                                 });
    if (sizeof(lines) == 0) return ({ "", "" });

    // Build ({tag, sha}) pairs
    array(array(string)) tags = ({});
    foreach (lines; ; string line) {
        array(string) parts = line / "\t";
        if (sizeof(parts) >= 2) {
            string sha = parts[0];
            string tag = replace(parts[-1], "refs/tags/", "");
            tags += ({ ({ tag, sha }) });
        }
    }

    if (sizeof(tags) == 0) return ({ "", "" });

    // Sort by semver (highest first), extract tag names
    array(string) tag_names = column(tags, 0);
    tag_names = sort_tags_semver(tag_names);
    string best = tag_names[0];

    // Find the SHA for the best tag
    foreach (tags; ; array(string) t)
        if (t[0] == best)
            return ({ best, t[1] });

    return ({ best, "" });
}

//! Resolve latest tag. Returns ({tag, commit_sha}).
array(string) latest_tag(string type, string domain, string repo_path,
                         void|string version) {
    switch (type) {
        case "github":     return latest_tag_github(repo_path, version);
        case "gitlab":     return latest_tag_gitlab(repo_path, version);
        case "selfhosted": return latest_tag_selfhosted(domain, repo_path);
        default: die("cannot resolve tags for source type: " + type);
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
                + "/commits/" + tag,
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
            string encoded = replace(repo_path, "/", "%2F");
            array(int|string) result = http_get_safe(
                "https://gitlab.com/api/v4/projects/" + encoded
                + "/repository/commits/" + tag, 0, version);
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
            mapping r = Process.run(
                ({"git", "ls-remote", "https://" + domain + "/" + repo_path,
                  "refs/tags/" + tag}));
            if (r->exitcode == 0 && sizeof(r->stdout) > 0)
                return ((r->stdout / "\t")[0]);
            return 0;
        }
        default:
            die("unknown source type: " + type);
    }
}

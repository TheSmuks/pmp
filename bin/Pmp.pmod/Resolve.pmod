inherit .Helpers;
inherit .Http;

//! Get latest tag from GitHub.
array(string) latest_tag_github(string repo_path, void|string version) {
    string url = "https://api.github.com/repos/" + repo_path + "/tags";
    string body = http_get(url, github_auth_headers(), version);

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
            github_auth_headers(), version);
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
array(string) latest_tag_gitlab(string repo_path, void|string version) {
    string encoded = replace(repo_path, "/", "%2F");
    string url = "https://gitlab.com/api/v4/projects/"
                 + encoded + "/repository/tags";
    string body = http_get(url, 0, version);

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
                    return data->sha || "unknown";
            }
            return "unknown";
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

import .Helpers;
import .Config;
import .Http;
import .Semver;

//! Resolve the latest tag for a remote source.
//! @param type
//!   "github", "gitlab", or "selfhosted"
//! @param domain
//!   Domain for selfhosted sources (unused for github/gitlab)
//! @param repo_path
//!   Repository path (e.g. "owner/repo")
//! @param version
//!   Optional version hint for HTTP calls
//! @param die_on_error
//!   If true, dies on HTTP errors. If false, returns ({"", ""}).
private array(string) _resolve_remote(string type, string domain,
                                      string repo_path,
                                      void|string version,
                                      int(0..1) die_on_error) {
    switch (type) {
    case "github": {
        string base_url = "https://api.github.com/repos/" + repo_path;
        return _resolve_tags(
            lambda(int page) {
                string url = base_url + "/tags?per_page=100&page=" + page;
                if (die_on_error)
                    return http_get(url, github_auth_headers(), version);
                array(int|string) result = http_get_safe(url, github_auth_headers(), version);
                return result[0] == 200 && result[1];
            },
            "sha",
            lambda(string tag) {
                if (die_on_error) {
                    string body = http_get(
                        base_url + "/commits/" + _encode_tag(tag),
                        github_auth_headers(), version);
                    mixed commit_data;
                    mixed fallback_err = catch { commit_data = Standards.JSON.decode(body); };
                    if (!fallback_err && mappingp(commit_data))
                        return commit_data->sha || "";
                } else {
                    array(int|string) sha_result = http_get_safe(
                        base_url + "/commits/" + _encode_tag(tag),
                        github_auth_headers(), version);
                    if (sha_result[0] == 200) {
                        mixed commit_data;
                        mixed fallback_err = catch { commit_data = Standards.JSON.decode(sha_result[1]); };
                        if (!fallback_err && mappingp(commit_data))
                            return commit_data->sha || "";
                    }
                }
                return "";
            });
    }
    case "gitlab": {
        string encoded = Protocols.HTTP.percent_encode(repo_path);
        string base_url = "https://gitlab.com/api/v4/projects/" + encoded + "/repository";
        return _resolve_tags(
            lambda(int page) {
                string url = base_url + "/tags?per_page=100&page=" + page;
                if (die_on_error)
                    return http_get(url, 0, version);
                array(int|string) result = http_get_safe(url, 0, version);
                return result[0] == 200 && result[1];
            },
            "id");
    }
    case "selfhosted":
        if (die_on_error)
            return latest_tag_selfhosted(domain, repo_path);
        mixed err = catch {
            return latest_tag_selfhosted(domain, repo_path);
        };
        return ({ "", "" });
    default:
        if (die_on_error)
            die("cannot resolve tags for source type: " + type, EXIT_INTERNAL);
        return ({ "", "" });
    }
}

//! URL-encode a string for use in API path segments.
//! Uses Protocols.HTTP.percent_encode for full RFC 2396 coverage.
private string _encode_tag(string tag) {
    return Protocols.HTTP.percent_encode(tag);
}

//! Core tag resolution logic shared by github/gitlab variants.
//! @param fetch_page
//!   function(int page) → string body (or 0 on error)
//! @param sha_field
//!   "sha" for github, "id" for gitlab
//! @param fallback
//!   optional function(string tag) → string sha
private array(string) _resolve_tags(
    function(int:string) fetch_page,
    string sha_field,
    void|function(string:string) fallback)
{
    array(string) tag_names = ({});
    array(mapping) all_entries = ({});
    int page = 1;
    while (1) {
        string body = fetch_page(page);
        if (!body) break;
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
        sha = by_name[tag]->commit[sha_field] || "";
    if (sha == "" && fallback)
        sha = fallback(tag);
    return ({ tag, sha || "" });
}

//! Get latest tag from GitHub — returns highest semver, not most-recently-created.
//! Paginates through all tags (GitHub caps at 100 per page).
array(string) latest_tag_github(string repo_path, void|string version) {
    return _resolve_remote("github", "", repo_path, version, 1);
}

//! Get latest tag from GitLab — returns highest semver, not most-recently-created.
array(string) latest_tag_gitlab(string repo_path, void|string version) {
    return _resolve_remote("gitlab", "", repo_path, version, 1);
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
    return _resolve_remote(type, domain, repo_path, version, 1);
}

//! Non-dying variant of latest_tag_github for batch operations.
//! Uses http_get_safe so HTTP errors return ({"",""}) instead of killing the process.
array(string) latest_tag_github_safe(string repo_path, void|string version) {
    return _resolve_remote("github", "", repo_path, version, 0);
}

//! Non-dying variant of latest_tag_gitlab for batch operations.
//! Uses http_get_safe so HTTP errors return ({"",""}) instead of killing the process.
array(string) latest_tag_gitlab_safe(string repo_path, void|string version) {
    return _resolve_remote("gitlab", "", repo_path, version, 0);
}

//! Non-dying tag resolution for batch operations like cmd_outdated.
//! Returns ({"", ""}) on any failure instead of terminating the process.
array(string) latest_tag_safe(string type, string domain, string repo_path,
                               void|string version) {
    return _resolve_remote(type, domain, repo_path, version, 0);
}

//! Get the default branch of a GitHub repo.
//! Returns ({branch_name, commit_sha}) or ({"", ""}) on failure.
array(string) resolve_default_branch_github(string repo_path,
                                             void|string version) {
    string url = "https://api.github.com/repos/" + repo_path;
    array(int|string) result = http_get_safe(url, github_auth_headers(), version);
    if (result[0] == 200 && result[1]) {
        mixed data;
        mixed err = catch { data = Standards.JSON.decode(result[1]); };
        if (!err && mappingp(data) && data->default_branch) {
            string branch = data->default_branch;
            array(int|string) sha_result = http_get_safe(
                url + "/commits/" + branch,
                github_auth_headers(), version);
            if (sha_result[0] == 200 && sha_result[1]) {
                mixed sha_data;
                mixed sha_err = catch { sha_data = Standards.JSON.decode(sha_result[1]); };
                if (!sha_err && mappingp(sha_data) && sha_data->sha)
                    return ({ branch, sha_data->sha });
            }
        }
    }
    return ({ "", "" });
}

//! Get the default branch of a GitLab repo.
//! Returns ({branch_name, commit_sha}) or ({"", ""}) on failure.
array(string) resolve_default_branch_gitlab(string repo_path,
                                             void|string version) {
    string encoded = Protocols.HTTP.percent_encode(repo_path);
    string url = "https://gitlab.com/api/v4/projects/" + encoded;
    array(int|string) result = http_get_safe(url, 0, version);
    if (result[0] == 200 && result[1]) {
        mixed data;
        mixed err = catch { data = Standards.JSON.decode(result[1]); };
        if (!err && mappingp(data) && data->default_branch) {
            string branch = data->default_branch;
            array(int|string) sha_result = http_get_safe(
                "https://gitlab.com/api/v4/projects/" + encoded
                + "/repository/commits/" + _encode_tag(branch), 0, version);
            if (sha_result[0] == 200 && sha_result[1]) {
                mixed sha_data;
                mixed sha_err = catch { sha_data = Standards.JSON.decode(sha_result[1]); };
                if (!sha_err && mappingp(sha_data) && sha_data->id)
                    return ({ branch, sha_data->id });
            }
        }
    }
    return ({ "", "" });
}

//! Resolve the default branch for any source type.
//! Returns ({branch_name, commit_sha}) or ({"", ""}) on failure.
array(string) resolve_default_branch(string type, string domain,
                                       string repo_path,
                                       void|string version) {
    switch (type) {
        case "github":
            return resolve_default_branch_github(repo_path, version);
        case "gitlab":
            return resolve_default_branch_gitlab(repo_path, version);
        case "selfhosted":
            need_cmd("git");
            if (_is_private_host(domain))
                die("blocked: SSRF protection — refusing to ls-remote from private/internal address: " + domain);
            mapping r = Process.run(
                ({"git", "ls-remote", "--symref", "https://" + domain + "/" + repo_path}));
            if (r->exitcode == 0 && sizeof(r->stdout) > 0) {
                foreach (r->stdout / "\n"; ; string line) {
                    if (sizeof(line) == 0) continue;
                    if (has_prefix(line, "HEAD")) {
                        array(string) parts = line / "\t";
                        if (sizeof(parts) >= 1) {
                            string ref = parts[0];
                            if (has_prefix(ref, "HEAD ref: ")) {
                                string branch = replace(ref, "HEAD ref: ", "");
                                mapping sha_r = Process.run(
                                    ({"git", "ls-remote", "https://" + domain + "/" + repo_path, branch}));
                                if (sha_r->exitcode == 0 && sizeof(sha_r->stdout) > 0) {
                                    string sha = (sha_r->stdout / "\t")[0];
                                    if (sizeof(sha) > 0)
                                        return ({ replace(branch, "refs/heads/", ""), sha });
                                }
                            }
                        }
                    }
                }
            }
            return ({ "", "" });
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
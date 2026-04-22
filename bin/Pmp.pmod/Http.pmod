//! Extract the host (domain) from a URL string.
string _url_host(string url) {
    // Handle scheme://host/path
    string rest = url;
    int scheme_end = search(rest, "://");
    if (scheme_end >= 0)
        rest = rest[scheme_end + 3..];
    // Strip credentials user:pass@host
    int at_pos = search(rest, "@");
    if (at_pos >= 0)
        rest = rest[at_pos + 1..];
    // Strip path
    int slash_pos = search(rest, "/");
    if (slash_pos >= 0)
        rest = rest[..slash_pos - 1];
    // Strip port
    int colon_pos = search(rest, ":");
    if (colon_pos >= 0)
        rest = rest[..colon_pos - 1];
    return lower_case(rest);
}

//! Validate that a redirect target stays on the same domain or a subdomain.
int _redirect_allowed_by_host(string original_host, string redirect_url) {
    string redir_host = _url_host(redirect_url);
    if (original_host == redir_host)
        return 1;
    // Allow subdomain redirects (e.g., github.com → codeload.github.com)
    if (has_suffix(redir_host, "." + original_host))
        return 1;
    return 0;
}
inherit .Helpers;


//! HTTP GET — dies on error.
string http_get(string url, void|mapping(string:string) headers,
                void|string version) {
    version = version || "0.2.0";
    mapping request_headers = ([
        "user-agent": "pmp/" + version,
    ]);

    if (headers)
        request_headers |= headers;

    string original_host = _url_host(url);

    // Follow up to 5 HTTP 3xx redirects
    int max_redirects = 5;
    for (int i = 0; i <= max_redirects; i++) {
        Protocols.HTTP.Query con;
        mixed err = catch {
            con = Protocols.HTTP.do_method("GET", url, 0, request_headers);
        };

        if (err)
            die("failed to fetch " + url + ": " + describe_error(err));
        if (!con)
            die("failed to connect to " + url);

        // Handle redirects
        if (con->status >= 300 && con->status < 400) {
            string location = con->headers["location"];
            if (!location || sizeof(location) == 0)
                die(sprintf("HTTP %d with no Location header fetching %s",
                           con->status, url));
            if (!_redirect_allowed_by_host(original_host, location))
                die("redirect from " + url + " to " + location
                    + " blocked — domain mismatch");
            url = location;
            continue;
        }

        if (con->status != 200)
            die(sprintf("HTTP %d fetching %s", con->status, url));

        string body = con->data();
        if (!body)
            die("no data from " + url);
        return body;
    }

    die("too many redirects fetching " + url);
}

array(int|string) http_get_safe(string url, void|mapping(string:string) headers,
                                 void|string version) {
    version = version || "0.2.0";
    mapping request_headers = ([
        "user-agent": "pmp/" + version,
    ]);

    if (headers)
        request_headers |= headers;

    string original_host = _url_host(url);

    // Follow up to 5 HTTP 3xx redirects
    int max_redirects = 5;
    for (int i = 0; i <= max_redirects; i++) {
        Protocols.HTTP.Query con;
        mixed err = catch {
            con = Protocols.HTTP.do_method("GET", url, 0, request_headers);
        };

        if (err || !con)
            return ({ 0, "" });

        // Handle redirects
        if (con->status >= 300 && con->status < 400) {
            string location = con->headers["location"];
            if (!location || sizeof(location) == 0)
                return ({ con->status, "" });
            if (!_redirect_allowed_by_host(original_host, location)) {
                werror("pmp: redirect from " + url + " to " + location
                       + " blocked — domain mismatch\n");
                return ({ 0, "" });
            }
            url = location;
            continue;
        }

        string body = con->data() || "";
        return ({ con->status, body });
    }

    return ({ 0, "" });
}

//! Build auth headers if GITHUB_TOKEN is set.
void|mapping github_auth_headers() {
    string token = getenv("GITHUB_TOKEN");
    if (!token || token == "") return 0;
    info("using GITHUB_TOKEN for authentication");
    return (["authorization": "token " + token]);
}

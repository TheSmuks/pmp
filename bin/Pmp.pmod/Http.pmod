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

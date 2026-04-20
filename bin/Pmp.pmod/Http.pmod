inherit .Helpers;


//! HTTP GET — dies on error.
string http_get(string url, void|mapping(string:string) headers,
                void|string version) {
    version = version || "0.2.0";
    Protocols.HTTP.Query con;
    mapping request_headers = ([
        "user-agent": "pmp/" + version,
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
array(int|string) http_get_safe(string url, void|mapping(string:string) headers,
                                 void|string version) {
    version = version || "0.2.0";
    Protocols.HTTP.Query con;
    mapping request_headers = ([
        "user-agent": "pmp/" + version,
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

//! Build auth headers if GITHUB_TOKEN is set.
void|mapping github_auth_headers() {
    string token = getenv("GITHUB_TOKEN");
    if (!token || token == "") return 0;
    info("using GITHUB_TOKEN for authentication");
    return (["authorization": "token " + token]);
}

//! HTTP transport with retry, timeouts, and hardening.
//!
//! Features:
//!   - Thread-based timeouts (separate connect/read)
//!   - Exponential backoff with jitter on transient failures
//!   - Retry-After header support for 429 responses
//!   - Response body size limit (100 MB)
//!   - Open redirect protection

inherit .Helpers;

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
    // Handle bracketed IPv6: [::1] or [::ffff:10.0.0.1]
    if (sizeof(rest) > 0 && rest[0] == '[') {
        int close_bracket = search(rest, "]");
        if (close_bracket >= 0) {
            rest = rest[1..close_bracket - 1];
            return lower_case(rest);
        }
        // Malformed bracket — return as-is so IPv6 checks in _is_private_host can match
        return lower_case(rest);
    }
    // Strip port
    int colon_pos = search(rest, ":");
    if (colon_pos >= 0)
        rest = rest[..colon_pos - 1];
    return lower_case(rest);
}

//! Check whether a hostname points to a private/internal address.
//! Returns 1 if the host should be blocked (SSRF protection).
int _is_private_host(string host) {
    string h = lower_case(host);
    // Literal loopback / wildcard
    if (h == "localhost" || has_prefix(h, "127.") || h == "0.0.0.0")
        return 1;
    // IPv6 loopback
    if (h == "::1")
        return 1;
    // IPv6-mapped IPv4 private addresses
    if (has_prefix(h, "::ffff:")) {
        string mapped = h[7..];
        if (has_value(mapped, ".")) {
            // Dotted-decimal format: ::ffff:127.0.0.1
            return _is_private_host(mapped);
        } else {
            // Hex format: ::ffff:7f00:1 → 127.0.0.1
            array(string) hex_parts = mapped / ":";
            if (sizeof(hex_parts) == 2) {
                int hi = (int)("0x" + hex_parts[0]);
                int lo = (int)("0x" + hex_parts[1]);
                if (hi >= 0 && lo >= 0) {
                    int a = (hi >> 8) & 0xff;
                    int b = hi & 0xff;
                    int c = (lo >> 8) & 0xff;
                    int d = lo & 0xff;
                    string ipv4 = sprintf("%d.%d.%d.%d", a, b, c, d);
                    return _is_private_host(ipv4);
                }
            }
            return 1; // Unknown hex format — treat as private (safe default)
        }
    }
    // 10.0.0.0/8
    if (has_prefix(h, "10."))
        return 1;
    // 192.168.0.0/16
    if (has_prefix(h, "192.168."))
        return 1;
    // 169.254.0.0/16 (link-local / cloud metadata)
    if (has_prefix(h, "169.254."))
        return 1;
    // 172.16.0.0/12 — 172.16.x.x through 172.31.x.x
    if (has_prefix(h, "172.")) {
        string rest = h[4..];
        int dot = search(rest, ".");
        if (dot > 0) {
            int second_octet = (int)rest[..dot - 1];
            if (second_octet >= 16 && second_octet <= 31)
                return 1;
        }
    }
    // IPv6 unique local fc00::/7 and link-local fe80::/10
    // Only apply to actual IPv6 addresses (contain colons)
    if (has_value(h, ":")) {
        if (has_prefix(h, "fc") || has_prefix(h, "fd"))
            return 1;
        if (has_prefix(h, "fe80"))
            return 1;
    }
    return 0;
}

int _redirect_allowed_by_host(string original_host, string redirect_url) {
    string redir_host = _url_host(redirect_url);
    // Block private/internal redirect targets even if domain matches
    if (_is_private_host(redir_host))
        return 0;
    if (original_host == redir_host)
        return 1;
    // Allow subdomain redirects (e.g., github.com -> codeload.github.com)
    if (has_suffix(redir_host, "." + original_host))
        return 1;
    return 0;
}

// Timeout constants (seconds). Match uv defaults.
constant HTTP_CONNECT_TIMEOUT = 10;
constant HTTP_READ_TIMEOUT = 30;
// Maximum retries for transient failures (429, 5xx, connection errors)
constant HTTP_MAX_RETRIES = 3;
// Maximum response body size (100 MB)
constant HTTP_MAX_BODY_SIZE = 100 * 1024 * 1024;

//! Perform an HTTP GET request with retry on transient failures.
//! Wraps _do_get_single with exponential backoff + jitter.
//! @param timeout_secs
//!   Override for read timeout (e.g., larger for tarball downloads).
object _do_get(string url, mapping request_headers,
                                             int|void timeout_secs) {
    timeout_secs = timeout_secs || HTTP_READ_TIMEOUT;
    float delay = 1.0;
    for (int attempt = 0; attempt < HTTP_MAX_RETRIES; attempt++) {
        if (attempt > 0) {
            // Add jitter: delay * (0.5 + random * 0.5) gives 50-100% of base
            float jittered = delay * (0.5 + random(1.0) * 0.5);
            info(sprintf("retrying %s (attempt %d/%d, waiting %.1fs)",
                _url_host(url), attempt + 1, HTTP_MAX_RETRIES, jittered));
            sleep(jittered);
            delay *= 2.0;
        }

        object con = _do_get_single(url, request_headers, timeout_secs);
        if (!con) {
            // Connection error — retry
            continue;
        }
        if (con->status == 429) {
            // Rate limited — respect Retry-After header
            string retry_after = con->headers["retry-after"];
            if (retry_after) {
                int ra_secs = min((int)retry_after, 60);
                if (ra_secs > 0) {
                    float wait = (float)max(delay, (float)ra_secs);
                    info(sprintf("rate limited by %s — waiting %.0fs (Retry-After)",
                        _url_host(url), wait));
                    sleep(wait);
                    // Don't double the delay for Retry-After responses
                    continue;
                }
            }
            continue;
        }
        if (con->status >= 500 && con->status < 600) {
            // Transient server error — retry
            continue;
        }
        // Success or non-retryable error
        return con;
    }
    // All retries exhausted
    return 0;
}

//! Single HTTP GET attempt wrapped in a thread-based timeout.
//! Returns the Protocols.HTTP.Query object on success, or 0 on timeout/error.
object _do_get_single(string url, mapping request_headers,
                                             int timeout_secs) {
    object mutex = Thread.Mutex();
    object key = mutex->lock();
    object cond = Thread.Condition();
    int done = 0;
    object result = 0;
    string error_msg = "";
    object http_thread = 0;

    // Resolve proxy from environment (HTTPS_PROXY, https_proxy, HTTP_PROXY, http_proxy)
    string proxy_url = getenv("HTTPS_PROXY") || getenv("https_proxy")
        || getenv("HTTP_PROXY") || getenv("http_proxy") || "";

    http_thread = Thread.Thread(lambda() {
        mixed err = catch {
            Protocols.HTTP.Query con = Protocols.HTTP.Query();
            con->timeout = HTTP_CONNECT_TIMEOUT;
            con->data_timeout = timeout_secs;
            // Set proxy if configured
            if (sizeof(proxy_url) > 0) {
                // Parse proxy URL: http://host:port
                string proxy_host = proxy_url;
                int proxy_port = 8080;
                if (has_prefix(proxy_host, "http://"))
                    proxy_host = proxy_host[7..];
                else if (has_prefix(proxy_host, "https://"))
                    proxy_host = proxy_host[8..];
                // Strip trailing slash
                if (has_suffix(proxy_host, "/"))
                    proxy_host = proxy_host[..<1];
                // Extract port
                int colon_pos = search(reverse(proxy_host), ":");
                if (colon_pos >= 0) {
                    int real_pos = sizeof(proxy_host) - 1 - colon_pos;
                    proxy_port = (int)proxy_host[real_pos + 1..];
                    proxy_host = proxy_host[..real_pos - 1];
                }
                con->proxy = ({ proxy_host, proxy_port });
            }
            Protocols.HTTP.do_method("GET", url, 0, request_headers, con);
            result = con;
        };
        if (err)
            error_msg = describe_error(err);
        object lkey = mutex->lock();
        done = 1;
        cond->signal();
        lkey = 0; // release
    });

    mixed wait_err = catch { cond->wait(key, (float)timeout_secs); };
    key = 0;

    if (!done) {
        // Thread is still running — wait briefly for it to finish
        // (Pike doesn't support thread cancellation, but we avoid leaking
        // the handle by waiting a short grace period)
        if (http_thread) {
            catch { http_thread->wait((float)HTTP_CONNECT_TIMEOUT); };
        }
        if (sizeof(error_msg) > 0)
            warn("HTTP request failed: " + error_msg);
        return 0;
    }
    if (http_thread) catch { http_thread->wait(); };
    return result;
}

//! HTTP GET — dies on error. Uses thread-based timeout.
//! Error messages include host (not full URL — may contain tokens in future).
string http_get(string url, void|mapping(string:string) headers,
                void|string version) {
    version = version || "0.2.0";
    mapping request_headers = ([
        "user-agent": "pmp/" + version,
    ]);

    if (headers)
        request_headers |= headers;

    string original_host = _url_host(url);
    if (_is_private_host(original_host))
        die("blocked: SSRF protection — refusing to fetch private/internal address: " + original_host);

    // Follow up to 5 HTTP 3xx redirects
    int max_redirects = 5;
    for (int i = 0; i <= max_redirects; i++) {
        Protocols.HTTP.Query con = _do_get(url, request_headers);

        if (!con)
            die("failed to fetch " + _url_host(url)
                + " (timeout or connection error after "
                + HTTP_MAX_RETRIES + " attempts)");

        // Handle redirects
        if (con->status >= 300 && con->status < 400) {
            string location = con->headers["location"];
            if (!location || sizeof(location) == 0)
                die(sprintf("HTTP %d with no Location header fetching %s",
                           con->status, _url_host(url)));
            if (!_redirect_allowed_by_host(original_host, location))
                die("redirect from " + _url_host(url) + " to " + _url_host(location)
                    + " blocked — domain mismatch");
            url = location;
            continue;
        }

        if (con->status != 200)
            die(sprintf("HTTP %d fetching %s", con->status, _url_host(url)));

        string body = con->data();
        if (!body)
            die("no data from " + _url_host(url));

        // Body size limit — prevent OOM from malicious/broken servers
        if (sizeof(body) > HTTP_MAX_BODY_SIZE)
            die(sprintf("response from %s exceeds %d MB limit (%d bytes)",
                _url_host(url), HTTP_MAX_BODY_SIZE / (1024 * 1024),
                sizeof(body)));

        return body;
    }

    die("too many redirects fetching " + _url_host(url));
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
    if (_is_private_host(original_host)) {
        werror("pmp: blocked: SSRF protection — refusing to fetch private/internal address: " + original_host + "\n");
        return ({ 0, "" });
    }

    // Follow up to 5 HTTP 3xx redirects
    int max_redirects = 5;
    for (int i = 0; i <= max_redirects; i++) {
        Protocols.HTTP.Query con = _do_get(url, request_headers);

        if (!con)
            return ({ 0, "" });

        // Handle redirects
        if (con->status >= 300 && con->status < 400) {
            string location = con->headers["location"];
            if (!location || sizeof(location) == 0)
                return ({ con->status, "" });
            if (!_redirect_allowed_by_host(original_host, location)) {
                werror("pmp: redirect from " + _url_host(url) + " to "
                       + _url_host(location) + " blocked — domain mismatch\n");
                return ({ 0, "" });
            }
            url = location;
            continue;
        }

        string body = con->data() || "";

        // Body size limit
        if (sizeof(body) > HTTP_MAX_BODY_SIZE) {
            warn(sprintf("response from %s exceeds %d MB limit",
                _url_host(url), HTTP_MAX_BODY_SIZE / (1024 * 1024)));
            return ({ 0, "" });
        }

        return ({ con->status, body });
    }

    return ({ 0, "" });
}

//! Build auth headers if GITHUB_TOKEN is set.
void|mapping github_auth_headers() {
    string token = getenv("GITHUB_TOKEN");
    if (!token || token == "") return 0;
    debug("using GITHUB_TOKEN for authentication");
    return (["authorization": "token " + token]);
}

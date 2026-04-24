//! HTTP transport with retry, timeouts, and hardening.
//!
//! Features:
//!   - Thread-based timeouts (separate connect/read)
//!   - Exponential backoff with jitter on transient failures
//!   - Retry-After header support for 429 responses
//!   - Response body size limit (100 MB)
//!   - Open redirect protection

inherit .Helpers;

protected Regexp RE_HEX = Regexp("^[0-9a-fA-F]+$");
protected Regexp RE_OCTAL = Regexp("^[0-7]+$");
protected Regexp RE_DIGITS = Regexp("^[0-9]+$");

//! Check if a redirect from original_url to location would be an HTTPS→HTTP downgrade.
private int(0..1) _is_https_downgrade(string original_url, string location) {
    string orig_scheme = "";
    mixed e1 = catch { orig_scheme = lower_case(Standards.URI(original_url)->scheme); };
    if (orig_scheme != "https") return 0;
    string loc_scheme = "";
    mixed e2 = catch { loc_scheme = lower_case(Standards.URI(location)->scheme); };
    return loc_scheme == "http";
}

//! Extract the host (domain) from a URL string.
//! Uses Standards.URI for RFC 3986 compliant parsing.
string _url_host(string url) {
    mixed err = catch {
        object u = Standards.URI(url);
        if (u->host && sizeof(u->host))
            return lower_case(u->host);
    };
    // Fallback for malformed URLs — extract host manually
    string rest = url;
    int scheme_end = search(rest, "://");
    if (scheme_end >= 0)
        rest = rest[scheme_end + 3..];
    // Strip credentials
    int at_pos = search(rest, "@");
    int slash_pos = search(rest, "/");
    if (at_pos >= 0 && (slash_pos < 0 || at_pos < slash_pos))
        rest = rest[at_pos + 1..];
    slash_pos = search(rest, "/");
    if (slash_pos >= 0)
        rest = rest[..slash_pos - 1];
    // Handle bracketed IPv6
    if (sizeof(rest) > 0 && rest[0] == '[') {
        int close_bracket = search(rest, "]");
        if (close_bracket >= 0)
            return lower_case(rest[1..close_bracket - 1]);
        // Malformed bracket — return content after [ for SSRF check
        return lower_case(rest[1..]);
    }
    int colon_pos = search(rest, ":");
    if (colon_pos >= 0)
        rest = rest[..colon_pos - 1];
    return lower_case(rest);
}

//! Check whether a hostname points to a private/internal address.
//! Returns 1 if the host should be blocked (SSRF protection).
//! Normalize octal/hex IPv4 octets to decimal.
//! Pike's (int) does NOT handle 0x/0 prefixes — use sscanf.
//! Parse integer with octal (0x/0X hex, 0 octal) prefix support.
//! Returns -1 on parse failure (non-numeric input).
protected int _parse_int(string s) {
    if (sizeof(s) == 0) return -1;
    if (has_prefix(s, "0x") || has_prefix(s, "0X")) {
        if (sizeof(s) == 2) return -1;
        // Validate hex digits only
        if (!RE_HEX->match(s[2..])) return -1;
        int val;
        sscanf(s[2..], "%x", val);
        return val;
    }
    if (sizeof(s) > 1 && s[0] == '0') {
        // Validate octal digits only
        if (!RE_OCTAL->match(s[1..])) return -1;
        int val;
        sscanf(s[1..], "%o", val);
        return val;
    }
    // Decimal: validate digits only
    if (!RE_DIGITS->match(s)) return -1;
    return (int)s;
}

protected string _normalize_ip_host(string host) {
    if (has_value(host, ":")) return host;
    if (!has_value(host, ".")) return host;
    array(string) parts = host / ".";
    // Expand 1/2/3-part inet_aton formats to 4 octets.
    // inet_aton semantics: values fill remaining bytes from the right.
    // a       → value fills all 4 bytes
    // a.b     → a is byte 0, value b fills bytes 1-3
    // a.b.c   → a,b are bytes 0,1; value c fills bytes 2,3
    // a.b.c.d → each is a single byte
    if (sizeof(parts) == 1) {
        int val = _parse_int(parts[0]);
        if (val < 0) return host;
        return sprintf("%d.%d.%d.%d",
            (val >> 24) & 0xff, (val >> 16) & 0xff,
            (val >> 8) & 0xff, val & 0xff);
    } else if (sizeof(parts) == 2) {
        int a = _parse_int(parts[0]);
        int b = _parse_int(parts[1]);
        if (a < 0 || a > 255 || b < 0) return host;
        return sprintf("%d.%d.%d.%d",
            a, (b >> 16) & 0xff, (b >> 8) & 0xff, b & 0xff);
    } else if (sizeof(parts) == 3) {
        int a = _parse_int(parts[0]);
        int b = _parse_int(parts[1]);
        int c = _parse_int(parts[2]);
        if (a < 0 || a > 255 || b < 0 || b > 255 || c < 0) return host;
        return sprintf("%d.%d.%d.%d",
            a, b, (c >> 8) & 0xff, c & 0xff);
    }
    if (sizeof(parts) != 4) return host;
    // Standard 4-part: normalize octal/hex octets to decimal
    foreach (parts; ; string p) {
        if (sizeof(p) == 0) return host;
        if (!((p[0] >= '0' && p[0] <= '9') || has_prefix(p, "0x") || has_prefix(p, "0X")))
            return host;
    }
    array(string) normalized = ({});
    foreach (parts; ; string p) {
        int val;
        if (has_prefix(p, "0x") || has_prefix(p, "0X")) {
            sscanf(p[2..], "%x", val);
        } else if (sizeof(p) > 1 && p[0] == '0') {
            sscanf(p[1..], "%o", val);
        } else {
            val = (int)p;
        }
        if (val < 0 || val > 255) return host;
        normalized += ({ (string)val });
    }
    return normalized * ".";
}


int _is_private_host(string host) {
    string h = lower_case(host);
    h = _normalize_ip_host(h);
    // Literal loopback / wildcard
    if (h == "localhost" || has_prefix(h, "127.") || has_prefix(h, "0."))
        return 1;
    // IPv6 unspecified and loopback (all forms including non-compressed)
    if (has_value(h, ":")) {
        // Expand :: to zero-groups for consistent matching
        string expanded = h;
        int dbl_colon = search(h, "::");
        if (dbl_colon >= 0) {
            string prefix = dbl_colon > 0 ? h[..dbl_colon - 1] : "";
            string suffix = h[dbl_colon + 2..];
            // Count existing groups (non-empty segments)
            int existing = 0;
            if (sizeof(prefix) > 0) existing += sizeof(prefix / ":");
            if (sizeof(suffix) > 0) existing += sizeof(suffix / ":");
            int fill = 8 - existing;
            if (fill > 0) {
                expanded = prefix;
                for (int i = 0; i < fill; i++) {
                    if (sizeof(expanded) > 0) expanded += ":";
                    expanded += "0";
                }
                if (sizeof(suffix) > 0) expanded += ":" + suffix;
            }
        }
        array(string) groups = expanded / ":";
        // Check loopback: all groups zero except last which is 1
        if (sizeof(groups) == 8) {
            int is_loopback = 1;
            for (int i = 0; i < 7; i++) {
                if (sizeof(groups[i]) > 0) { int v; sscanf(groups[i], "%x", v); if (v != 0) { is_loopback = 0; break; } }
            }
            if (is_loopback && sizeof(groups[7]) > 0) { int last; sscanf(groups[7], "%x", last); if (last == 1) return 1; }
            // Check unspecified: all groups zero
            int is_unspecified = 1;
            for (int i = 0; i < 8; i++) {
                if (sizeof(groups[i]) > 0) { int v; sscanf(groups[i], "%x", v); if (v != 0) { is_unspecified = 0; break; } }
            }
            if (is_unspecified) return 1;
        }
        // Check for IPv4-compatible/IPv4-mapped embedded addresses
        // When any group contains dots, it's dotted-decimal notation
        foreach (groups; ; string g) {
            if (has_value(g, ".")) {
                // Dotted-decimal embedded in IPv6 — check the IPv4 address
                return _is_private_host(g);
            }
        }
    }
    // IPv4-mapped IPv6 in non-compressed form
    // Handles: 0:0:0:0:0:ffff:XXXX:YYYY (8-group hex)
    //          0:0:0:0:0:ffff:A.B.C.D  (7-group mixed)
    //          0::ffff:XXXX:YYYY or 0::ffff:A.B.C.D (compressed)
    if (has_value(h, ":") && !has_prefix(h, "[")) {
        array(string) groups = h / ":";
        // Find 'ffff' marker anywhere in the address
        int ffff_idx = -1;
        for (int i = 0; i < sizeof(groups); i++) {
            if (lower_case(groups[i]) == "ffff") { ffff_idx = i; break; }
        }
        if (ffff_idx >= 0) {
            // Verify all groups before ffff are zero or empty (:: expansion)
            int all_zero = 1;
            for (int i = 0; i < ffff_idx; i++) {
                if (sizeof(groups[i]) > 0) { int v; sscanf(groups[i], "%x", v); if (v != 0) { all_zero = 0; break; } }
            }
            if (all_zero) {
                // Extract everything after ffff
                array(string) after = groups[ffff_idx + 1..];
                if (sizeof(after) == 1 && has_value(after[0], ".")) {
                    // Dotted-decimal: ffff:127.0.0.1
                    return _is_private_host(after[0]);
                } else if (sizeof(after) == 2) {
                    // Hex: ffff:7f00:1 → 127.0.0.1
                    int hi; sscanf(after[0], "%x", hi);
                    int lo; sscanf(after[1], "%x", lo);
                    if (hi >= 0 && lo >= 0) {
                        int a = (hi >> 8) & 0xff;
                        int b = hi & 0xff;
                        int c = (lo >> 8) & 0xff;
                        int d = lo & 0xff;
                        string ipv4 = sprintf("%d.%d.%d.%d", a, b, c, d);
                        return _is_private_host(ipv4);
                    }
                }
                return 1; // Unknown format — safe default
            }
        }
    }
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
                int hi; sscanf(hex_parts[0], "%x", hi);
                int lo; sscanf(hex_parts[1], "%x", lo);
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
    // 100.64.0.0/10 — Carrier-grade NAT (RFC 6598)
    if (has_prefix(h, "100.")) {
        string rest = h[4..];
        int dot = search(rest, ".");
        if (dot > 0) {
            int second_octet = (int)rest[..dot - 1];
            if (second_octet >= 64 && second_octet <= 127)
                return 1;
        }
    }
    // IPv6 unique local fc00::/7 and link-local fe80::/10
    // Only apply to actual IPv6 addresses (contain colons)
    if (has_value(h, ":")) {
        if (has_prefix(h, "fc") || has_prefix(h, "fd"))
            return 1;
        // fe80::/10 link-local — fe80 through febf
        if (sizeof(h) >= 2 && h[..1] == "fe") {
            // Third nibble 8-b covers fe80-febf
            if (sizeof(h) >= 3) {
                int nibble3 = h[2];
                if (nibble3 >= '8' && nibble3 <= 'b')
                    return 1;
            }
        }
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
            // Secondary rate limit — respect Retry-After header
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
        if (con->status == 403 && has_prefix(url, "https://api.github.com")
            && con->headers["x-ratelimit-remaining"] == "0") {
            // GitHub primary rate limit — 403 with x-ratelimit-remaining: 0.
            // Exponential backoff + jitter already applied above.
            // Check Retry-After if present, otherwise fall through to
            // the existing backoff.
            string retry_after = con->headers["retry-after"];
            if (retry_after) {
                int ra_secs = min((int)retry_after, 60);
                if (ra_secs > 0) {
                    float wait = (float)max(delay, (float)ra_secs);
                    info(sprintf("rate limited by %s — waiting %.0fs (Retry-After)",
                        _url_host(url), wait));
                    sleep(wait);
                    continue;
                }
            }
            continue;
        }
        if (con->status >= 500 && con->status < 600) {
            // Transient server error — retry
            continue;
        }
        // Non-retryable error
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
                mixed proxy_err = catch {
                    object pu = Standards.URI(proxy_url);
                    con->proxy = ({ pu->host, (int)pu->port || 8080 });
                };
                if (proxy_err)
                    die("invalid proxy URL: " + proxy_url);
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
            if (_is_https_downgrade(url, location)) {
                die("blocked: redirect from HTTPS to HTTP — refusing to expose credentials in cleartext");
            }
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
            // Block HTTPS→HTTP downgrade (credential/token exposure)
            if (_is_https_downgrade(url, location)) {
                werror("pmp: blocked: redirect from HTTPS to HTTP — refusing to expose credentials in cleartext\n");
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

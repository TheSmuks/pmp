inherit .Helpers;
inherit .Config;

//! HTTP response cache for reducing redundant API calls.
//! Stores responses at ~/.pike/cache/http/ with ETag/Last-Modified support.
//! TTL-based expiry prevents stale data.

// Cache directory
private string _cache_dir = "";

//! Get (and lazily create) the cache directory.
string cache_dir() {
    if (sizeof(_cache_dir) == 0)
        _cache_dir = combine_path(getenv("HOME") || "/tmp", ".pike/cache/http");
    if (!Stdio.is_dir(_cache_dir))
        Stdio.mkdirhier(_cache_dir);
    return _cache_dir;
}

//! Default TTL for cached responses (5 minutes).
constant CACHE_TTL = 300;

//! Compute a filesystem-safe cache key from a URL.
string _cache_key(string url) {
    return String.string2hex(Crypto.SHA256.hash(url));
}
//! Parse a cache entry's raw content into (header_mapping, body).
//! Returns 0 on failure.
private array(mapping(string:string)|string)|mixed _parse_cache_entry(string raw) {
    int sep = search(raw, "\n\n");
    if (sep < 0) return 0;
    string header_block = raw[..sep - 1];
    string body = raw[sep + 2..];
    mapping(string:string) headers = ([]);
    foreach (header_block / "\n"; ; string line) {
        string k, v;
        if (sscanf(line, "%s: %s", k, v) != 2) continue;
        headers[k] = v;
    }
    return ({ headers, body });
}

//! Look up a cached response. Returns 0 on miss, or mapping with:
//!   body: response body
//!   etag: ETag value (if any)
//!   last_modified: Last-Modified value (if any)
//!   cached_at: Unix timestamp when cached
//!   headers: mapping of conditional request headers to send
mapping|void cache_get(string url, void|int ttl_secs) {
    ttl_secs = ttl_secs || CACHE_TTL;
    string key = _cache_key(url);
    string path = combine_path(cache_dir(), key);

    if (!Stdio.exist(path)) return 0;

    string raw = Stdio.read_file(path);
    if (!raw || sizeof(raw) == 0) {
        rm(path);
        return 0;
    }
    // Parse cache entry: header lines (key: value) then blank line then body
    array(mapping(string:string)|string)|mixed parsed = _parse_cache_entry(raw);
    if (!parsed) {
        warn("removing corrupted cache entry (no header separator)");
        rm(path);
        return 0;
    }
    [mapping(string:string) headers, string body] = parsed;

    mapping entry = (["body": body]);
    int cached_at = (int)(headers["cached_at"] || "0");
    string etag = headers["etag"] || "";
    string last_modified = headers["last-modified"] || "";

    // Check TTL — treat missing/zero timestamp as expired (corrupt entry)
    if (cached_at <= 0 || (time() - cached_at) > ttl_secs) {
        if (cached_at <= 0) {
            warn("removing corrupted cache entry (invalid timestamp)");
            rm(path);
        }
        return 0;
    }

    entry->cached_at = cached_at;

    // Build conditional request headers
    mapping cond_headers = ([]);
    if (sizeof(etag) > 0) {
        cond_headers["if-none-match"] = etag;
        entry->etag = etag;
    }
    if (sizeof(last_modified) > 0) {
        cond_headers["if-modified-since"] = last_modified;
        entry->last_modified = last_modified;
    }
    entry->headers = cond_headers;

    return entry;
}

//! Store a response in cache.
//! @param url
//!   The request URL.
//! @param body
//!   The response body.
//! @param headers
//!   The response headers (to extract ETag, Last-Modified).
void cache_put(string url, string body, void|mapping headers) {
    string key = _cache_key(url);
    string path = combine_path(cache_dir(), key);

    String.Buffer buf = String.Buffer();
    buf->add("cached_at: " + time() + "\n");

    if (headers) {
        // Extract caching headers, writing each exactly once.
        // Headers may arrive with varying case; use case-insensitive match.
        int wrote_etag = 0;
        int wrote_lm = 0;
        foreach (headers; string k;) {
            if (lower_case(k) == "etag" && !wrote_etag) {
                buf->add("etag: " + headers[k] + "\n");
                wrote_etag = 1;
            }
            if (lower_case(k) == "last-modified" && !wrote_lm) {
                buf->add("last-modified: " + headers[k] + "\n");
                wrote_lm = 1;
            }
        }
    }

    buf->add("\n");
    buf->add(body);

    // Atomic write via tmp + rename
    string tmp_path = path + ".tmp." + getpid();
    Stdio.write_file(tmp_path, buf->get());
    if (!mv(tmp_path, path)) {
        // Cross-filesystem fallback
        catch { Stdio.write_file(path, Stdio.read_file(tmp_path)); rm(tmp_path); };
    }
}

//! Remove all cached entries.
void cache_clear() {
    string dir = cache_dir();
    if (!Stdio.is_dir(dir)) return;
    foreach (get_dir(dir) || ({}); ; string f) {
        string full = combine_path(dir, f);
        if (Stdio.is_file(full)) rm(full);
    }
    info("HTTP cache cleared");
}

//! Remove expired entries (older than TTL).
//! @param ttl_secs
//!   Maximum age in seconds (default: 1 hour for prune).
void cache_prune(void|int ttl_secs) {
    ttl_secs = ttl_secs || 3600;
    string dir = cache_dir();
    if (!Stdio.is_dir(dir)) return;
    int pruned = 0;
    foreach (get_dir(dir) || ({}); ; string f) {
        string full = combine_path(dir, f);
        if (!Stdio.is_file(full)) continue;
        string raw = Stdio.read_file(full);
        int cached_at = 0;
        if (raw && sizeof(raw)) {
            array(mapping(string:string)|string)|mixed parsed = _parse_cache_entry(raw);
            if (parsed) {
                [mapping(string:string) headers, string body] = parsed;
                cached_at = (int)(headers["cached_at"] || "0");
            }
        }
        // Prune if missing/corrupt or expired
        if (cached_at <= 0 || (time() - cached_at) > ttl_secs) {
            rm(full);
            pruned++;
        }
    }
    if (pruned > 0)
        info(sprintf("pruned %d expired cache entries", pruned));
}

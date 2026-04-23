//! Adversarial tests for Pmp.Cache — edge cases, corruption, and boundary conditions.

import PUnit;
import Pmp.Cache;
inherit PUnit.TestCase;

// Track URLs we've cached so teardown can clean them up.
protected array(string) cached_urls = ({});

void setup() {
    cached_urls = ({});
}

void teardown() {
    // Remove entries we created — avoids polluting real cache.
    foreach (cached_urls; ; string url) {
        string key = _cache_key(url);
        string path = combine_path(cache_dir(), key);
        if (Stdio.exist(path))
            rm(path);
    }
}

// Helper: compute cache file path for a URL.
protected string cache_path_for(string url) {
    return combine_path(cache_dir(), _cache_key(url));
}

// Helper: write a raw file into the cache dir, bypassing cache_put.
protected void write_raw_cache_entry(string url, string content) {
    string key = _cache_key(url);
    string path = combine_path(cache_dir(), key);
    Stdio.write_file(path, content);
    cached_urls += ({ url });
}

// ── Basic get/put semantics ──────────────────────────────────────────

void test_cache_get_nonexistent() {
    mapping result = cache_get("https://example.com/nonexistent-" + time());
    assert_equal(0, result);
}

void test_cache_put_get_roundtrip() {
    string url = "https://example.com/roundtrip-" + time();
    string body = "Hello, world!";
    cache_put(url, body);
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal(body, result->body);
}

void test_cache_key_determinism() {
    string url = "https://example.com/deterministic";
    assert_equal(_cache_key(url), _cache_key(url));
}

void test_cache_key_uniqueness() {
    string key_a = _cache_key("https://example.com/a");
    string key_b = _cache_key("https://example.com/b");
    assert_true(key_a != key_b);
}

// ── Header preservation ──────────────────────────────────────────────

void test_cache_put_with_etag() {
    string url = "https://example.com/etag-test-" + time();
    cache_put(url, "body", (["etag": "\"abc123\""]));
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal("\"abc123\"", result->etag);
}

void test_cache_put_with_last_modified() {
    string url = "https://example.com/lm-test-" + time();
    cache_put(url, "body", (["last-modified": "Wed, 21 Oct 2015 07:28:00 GMT"]));
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal("Wed, 21 Oct 2015 07:28:00 GMT", result->last_modified);
}

void test_cache_get_conditional_headers() {
    string url = "https://example.com/cond-test-" + time();
    cache_put(url, "body", ([
        "etag": "\"etag-val\"",
        "last-modified": "Thu, 01 Jan 2025 00:00:00 GMT",
    ]));
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_true(mappingp(result->headers));
    assert_equal("\"etag-val\"", result->headers["if-none-match"]);
    assert_equal("Thu, 01 Jan 2025 00:00:00 GMT", result->headers["if-modified-since"]);
}

// ── Expiry ───────────────────────────────────────────────────────────

void test_cache_get_expired() {
    // Write a cache entry with cached_at far enough in the past to be expired.
    // Default TTL is 300 seconds. Use cached_at = time() - 600 so it's definitely expired.
    string url = "https://example.com/expired-" + time();
    int past = time() - 600;
    write_raw_cache_entry(url,
        "cached_at: " + past + "\n\nbody text");

    // cache_get with default TTL should consider this expired.
    mapping result = cache_get(url);
    assert_equal(0, result);
}

// ── Clear / overwrite ────────────────────────────────────────────────

void test_cache_clear() {
    string url_a = "https://example.com/clear-a-" + time();
    string url_b = "https://example.com/clear-b-" + time();
    cache_put(url_a, "body_a");
    cache_put(url_b, "body_b");
    cached_urls += ({ url_a, url_b });

    // Verify they're cached.
    assert_true(cache_get(url_a) != 0);
    assert_true(cache_get(url_b) != 0);

    cache_clear();
    // After clear, our URLs are gone. Remove from cleanup list since
    // cache_clear already removed them.
    cached_urls = ({});

    assert_equal(0, cache_get(url_a));
    assert_equal(0, cache_get(url_b));
}

void test_cache_overwrite() {
    string url = "https://example.com/overwrite-" + time();
    cache_put(url, "first body");
    cached_urls += ({ url });

    cache_put(url, "second body");

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal("second body", result->body);
}

// ── Edge cases ───────────────────────────────────────────────────────

void test_cache_empty_body() {
    string url = "https://example.com/empty-body-" + time();
    cache_put(url, "");
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal("", result->body);
}

void test_cache_no_headers() {
    string url = "https://example.com/no-headers-" + time();
    cache_put(url, "body text");
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_true(mappingp(result->headers));
    assert_equal(0, sizeof(result->headers));
    assert_equal(0, result->etag);
    assert_equal(0, result->last_modified);
}

// ── Corrupt entries ──────────────────────────────────────────────────

void test_cache_corrupt_no_separator() {
    // File with header lines but no blank-line separator — cache_get should return 0.
    string url = "https://example.com/corrupt-nosep-" + time();
    write_raw_cache_entry(url,
        "cached_at: " + time() + "\netag: \"x\"\nno blank line here");

    assert_equal(0, cache_get(url));
}

void test_cache_corrupt_no_cached_at() {
    // File with separator but no cached_at header — treated as expired (cached_at=0).
    string url = "https://example.com/corrupt-noca-" + time();
    write_raw_cache_entry(url,
        "etag: \"something\"\n\nbody");

    assert_equal(0, cache_get(url));
}

void test_cache_corrupt_negative_cached_at() {
    // File with cached_at: -1 — code checks cached_at <= 0, should return 0.
    string url = "https://example.com/corrupt-neg-" + time();
    write_raw_cache_entry(url,
        "cached_at: -1\n\nbody");

    assert_equal(0, cache_get(url));
}

// ── Etag deduplication ─────────────────────────────────────────────

void test_cache_etag_case_insensitive() {
    // Header "ETag" (mixed case) should be stored and retrievable as etag
    string url = "https://example.com/etag-case-" + time();
    cache_put(url, "body", (["ETag": "\"mixed-case\""]));
    cached_urls += ({ url });

    mapping result = cache_get(url);
    assert_true(result != 0);
    assert_equal("\"mixed-case\"", result->etag);
}

void test_cache_etag_no_duplicate_with_both_cases() {
    // If headers have both "etag" and "ETag", only one should be written
    string url = "https://example.com/etag-dup-" + time();
    cache_put(url, "body", (["etag": "\"lower\"", "ETag": "\"upper\""]));
    cached_urls += ({ url });

    // Read the raw cache file and verify only one etag line
    string raw = Stdio.read_file(cache_path_for(url));
    int etag_count = 0;
    foreach (raw / "\n"; ; string line)
        if (has_prefix(line, "etag: ")) etag_count++;
    assert_equal(1, etag_count);
}
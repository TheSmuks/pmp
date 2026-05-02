//! Adversarial tests for Pmp.Http — pure functions and auth header edge cases.

import PUnit;
import Pmp.Helpers;
import Pmp.Http;
inherit PUnit.TestCase;

// ── _url_host ─────────────────────────────────────────────────────────

void test_url_host_simple() {
    assert_equal("github.com", _url_host("https://github.com/owner/repo"));
}

void test_url_host_with_port() {
    assert_equal("github.com", _url_host("https://github.com:8443/owner/repo"));
}

void test_url_host_with_credentials() {
    assert_equal("github.com",
                 _url_host("https://user:pass@github.com/owner/repo"));
}

void test_url_host_no_scheme() {
    assert_equal("github.com", _url_host("github.com/owner/repo"));
}

void test_url_host_empty() {
    assert_equal("", _url_host(""));
}

// ── _redirect_allowed_by_host ─────────────────────────────────────────

void test_redirect_same_domain() {
    assert_equal(1,
        _redirect_allowed_by_host("github.com",
                                  "https://github.com/other/path"));
}

void test_redirect_subdomain() {
    assert_equal(1,
        _redirect_allowed_by_host("github.com",
                                  "https://codeload.github.com/owner/repo"));
}

void test_redirect_cross_domain() {
    assert_equal(0,
        _redirect_allowed_by_host("github.com",
                                  "https://evil.com/path"));
}

void test_redirect_case_insensitive() {
    // _url_host always lowercases, so original_host is always lowercase.
    // The redirect URL is also lowercased by _url_host internally.
    assert_equal(1,
        _redirect_allowed_by_host("github.com",
                                  "https://GITHUB.COM/path"));
}

// ── Auth headers (env-var gated) ──────────────────────────────────────

void test_github_auth_headers_with_token() {
    string orig = getenv("GITHUB_TOKEN") || "";
    putenv("GITHUB_TOKEN", "mytesttoken");
    mapping headers = github_auth_headers();
    putenv("GITHUB_TOKEN", orig);
    assert_true(mappingp(headers));
    assert_equal("token mytesttoken", headers["authorization"]);
}

void test_github_auth_headers_without_token() {
    string orig = getenv("GITHUB_TOKEN") || "";
    putenv("GITHUB_TOKEN", "");
    mixed result = github_auth_headers();
    putenv("GITHUB_TOKEN", orig);
    assert_equal(0, result);
}


// ── _is_private_host IPv4-in-IPv6 (SSRF bypass) ─────────────────

void test_private_host_ipv4_in_ipv6_loopback() {
    assert_equal(1, _is_private_host("::127.0.0.1"));
}

void test_private_host_ipv4_in_ipv6_ten_network() {
    assert_equal(1, _is_private_host("::10.0.0.1"));
}

void test_private_host_ipv4_in_ipv6_cgnat() {
    assert_equal(1, _is_private_host("::192.168.1.1"));
}

void test_private_host_ipv4_in_ipv6_linklocal() {
    assert_equal(1, _is_private_host("::169.254.169.254"));
}

void test_private_host_ipv4_in_ipv6_expanded_loopback() {
    assert_equal(1, _is_private_host("0:0:0:0:0:0:127.0.0.1"));
}

void test_private_host_ipv4_in_ipv6_expanded_ten() {
    assert_equal(1, _is_private_host("0:0:0:0:0:0:10.0.0.1"));
}

// ── sanitize_url ──────────────────────────────────────────────────

void test_sanitize_url_with_token() {
    assert_equal("https://***@github.com/owner/repo",
                 sanitize_url("https://token@github.com/owner/repo"));
}
void test_sanitize_url_with_user_pass() {
    assert_equal("https://***@host/path",
                 sanitize_url("https://user:pass@host/path"));
}
void test_sanitize_url_no_credentials() {
    assert_equal("https://github.com/owner/repo",
                 sanitize_url("https://github.com/owner/repo"));
}
void test_sanitize_url_non_url() {
    assert_equal("not-a-url", sanitize_url("not-a-url"));
}
// ── _is_https_downgrade ─────────────────────────────────────────────

void test_https_downgrade_blocked() {
    // HTTPS → HTTP downgrade should be blocked
    assert_equal(1, _is_https_downgrade("https://example.com/path", "http://example.com/other"));
}

void test_https_to_https_allowed() {
    assert_equal(0, _is_https_downgrade("https://example.com/path", "https://other.com/path"));
}

void test_http_to_http_allowed() {
    assert_equal(0, _is_https_downgrade("http://example.com/path", "http://example.com/other"));
}

// ── Integration: redirect following ─────────────────────────────────

void test_redirect_chain_followed() {
    // Test that GitHub tarball redirect is followed correctly.
    // GitHub returns 302 with location header pointing to codeload.github.com.
    // The redirect should be allowed since codeload.github.com is a subdomain.
    assert_equal(1, _redirect_allowed_by_host("github.com", "https://codeload.github.com/owner/repo/tar.gz/refs/tags/v1.0.0"));
}

void test_redirect_to_different_subdomain_allowed() {
    // GitHub might redirect to api subdomain in some cases
    assert_equal(1, _redirect_allowed_by_host("github.com", "https://api.github.com/repos/owner/repo"));
}

void test_redirect_blocked_https_to_http() {
    assert_equal(1, _is_https_downgrade("https://secure.example.com/path", "http://insecure.example.com/path"));
}

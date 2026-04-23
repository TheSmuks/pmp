//! Adversarial tests for Pmp.Http — pure functions and auth header edge cases.

import PUnit;
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

void test_gitlab_auth_headers_with_token() {
    string orig = getenv("GITLAB_TOKEN") || "";
    putenv("GITLAB_TOKEN", "mygltoken");
    mapping headers = gitlab_auth_headers();
    putenv("GITLAB_TOKEN", orig);
    assert_true(mappingp(headers));
    assert_equal("mygltoken", headers["private-token"]);
}

// ── IPv6 handling ───────────────────────────────────────────────────

void test_url_host_ipv6_with_port() {
    assert_equal("::1", _url_host("https://[::1]:8080/owner/repo"));
}

void test_url_host_ipv6_no_port() {
    assert_equal("::1", _url_host("https://[::1]/owner/repo"));
}

void test_url_host_ipv6_full() {
    assert_equal("2001:db8::1", _url_host("https://[2001:db8::1]:443/path"));
}

void test_parse_proxy_ipv6_with_port() {
    array result = _parse_proxy_url("http://[::1]:8080");
    assert_equal("::1", result[0]);
    assert_equal(8080, result[1]);
}

void test_parse_proxy_ipv6_no_port() {
    array result = _parse_proxy_url("http://[::1]");
    assert_equal("::1", result[0]);
    assert_equal(8080, result[1]);  // default port
}

void test_parse_proxy_ipv6_https() {
    array result = _parse_proxy_url("https://[fe80::1]:3128");
    assert_equal("fe80::1", result[0]);
    assert_equal(3128, result[1]);
}
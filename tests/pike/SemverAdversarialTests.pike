//! Adversarial tests for Pmp.Semver — edge cases for parse_semver,
//! compare_semver, compare_prerelease, classify_bump.

import PUnit;
import Pmp.Semver;
inherit PUnit.TestCase;

// ── parse_semver ─────────────────────────────────────────────────────

void test_parse_trailing_dash() {
    // "1.2.3-" — dash present but empty prerelease string after it
    mapping v = parse_semver("1.2.3-");
    assert_not_null(v);
    assert_equal(1, v["major"]);
    assert_equal(2, v["minor"]);
    assert_equal(3, v["patch"]);
    assert_equal("", v["prerelease"]);
}

void test_parse_empty_build_metadata() {
    // "1.2.3+" — plus present but empty build metadata, stripped per spec
    mapping v = parse_semver("1.2.3+");
    assert_not_null(v);
    assert_equal(1, v["major"]);
    assert_equal(2, v["minor"]);
    assert_equal(3, v["patch"]);
    assert_equal("", v["prerelease"]);
}

void test_parse_too_many_parts() {
    // More than 3 dot-separated numeric parts
    assert_equal(0, parse_semver("1.2.3.4.5"));
}

void test_parse_leading_dot() {
    assert_equal(0, parse_semver(".1.2.3"));
}

void test_parse_v_only() {
    assert_equal(0, parse_semver("v"));
}

void test_parse_double_v() {
    // "vv1.2.3" — second 'v' not stripped, becomes part of version string
    assert_equal(0, parse_semver("vv1.2.3"));
}

void test_parse_double_dot_prerelease() {
    // Parser doesn't validate prerelease format — ".." is preserved
    mapping v = parse_semver("1.2.3-alpha..beta");
    assert_not_null(v);
    assert_equal("alpha..beta", v["prerelease"]);
}

void test_parse_whitespace_prerelease() {
    // Tab in prerelease — parser treats it as a valid prerelease string
    mapping v = parse_semver("1.2.3-\t");
    assert_not_null(v);
    assert_equal("\t", v["prerelease"]);
}

void test_parse_unicode_prerelease() {
    // Greek alpha (U+03B1) and beta (U+03B2) in prerelease
    mapping v = parse_semver("1.2.3-\x03b1\x03b2");
    assert_not_null(v);
    assert_equal("\x03b1\x03b2", v["prerelease"]);
}

void test_parse_large_patch() {
    // Build a version with a large but valid patch number
    string ver = "1.0.999999999";  // 9 digits, fits in 64-bit int
    mapping v = parse_semver(ver);
    assert_not_null(v);
    assert_equal(1, v["major"]);
    assert_equal(0, v["minor"]);
    assert_equal(999999999, v["patch"]);
}
void test_parse_semver_partial_version() {
    // "1" is accepted by the parser with default minor=0, patch=0
    mapping v1 = parse_semver("1");
    assert_not_null(v1);
    assert_equal(1, v1["major"]);
    assert_equal(0, v1["minor"]);
    assert_equal(0, v1["patch"]);
    // "1.2" is accepted by the parser with default patch=0
    mapping v2 = parse_semver("1.2");
    assert_not_null(v2);
    assert_equal(0, v2["patch"]);
}

void test_parse_semver_bare_v() {
    // "v" with no digits
    assert_equal(0, parse_semver("v"));
}

void test_parse_semver_double_v() {
    // "vv1.2.3" — double v prefix
    assert_equal(0, parse_semver("vv1.2.3"));
}

void test_parse_semver_empty_string() {
    assert_equal(0, parse_semver(""));
}

void test_parse_semver_prerelease_with_special_chars() {
    // "1.0.0-alpha/beta" — slash not valid in prerelease per semver spec
    mapping v = parse_semver("1.0.0-alpha/beta");
    // Just verify it doesn't crash
    assert_not_null(v);
}

void test_classify_bump_null_inputs() {
    assert_equal("unknown", classify_bump(0, "1.0.0"));
    assert_equal("unknown", classify_bump("1.0.0", 0));
    assert_equal("unknown", classify_bump(0, 0));
}

void test_classify_bump_same_version() {
    assert_equal("none", classify_bump("1.0.0", "1.0.0"));
    assert_equal("none", classify_bump("v1.0.0", "v1.0.0"));
}

// ── compare_semver ───────────────────────────────────────────────────

void test_compare_many_prerelease_identifiers() {
    // Deep prerelease dot-identifiers: differs only at the last component
    mapping a = parse_semver("1.2.3-alpha.1.2.3.4.5");
    mapping b = parse_semver("1.2.3-alpha.1.2.3.4.6");
    assert_not_null(a);
    assert_not_null(b);
    assert_equal(-1, compare_semver(a, b));
    assert_equal(1, compare_semver(b, a));
}

// ── classify_bump ────────────────────────────────────────────────────

void test_classify_equal_returns_none() {
    assert_equal("none", classify_bump("v1.0.0", "v1.0.0"));
}

void test_classify_large_jump() {
    assert_equal("major", classify_bump("1.0.0", "999.999.999"));
}

// ── classify_bump: prerelease-to-non-prerelease transitions ────────

void test_classify_prerelease_to_patch() {
    // Bug fix: 1.0.0-alpha → 1.0.1 was misclassified as "prerelease"
    assert_equal("patch", classify_bump("1.0.0-alpha", "1.0.1"));
}

void test_classify_prerelease_to_minor() {
    assert_equal("minor", classify_bump("1.0.0-alpha", "1.1.0"));
}

void test_classify_prerelease_to_major() {
    assert_equal("major", classify_bump("1.0.0-alpha", "2.0.0"));
}

void test_classify_release_to_prerelease_same_mmp() {
    // 1.0.0 → 1.0.0-alpha: this is a downgrade, not a prerelease change
    assert_equal("downgrade", classify_bump("1.0.0", "1.0.0-alpha"));
}

void test_classify_prerelease_same_mmp() {
    // Same major.minor.patch, different prerelease: "prerelease"
    assert_equal("prerelease", classify_bump("1.0.0-alpha", "1.0.0-beta"));
}

void test_classify_prerelease_alpha_to_release() {
    // 1.0.0-alpha → 1.0.0: dropping prerelease = "prerelease"
    assert_equal("prerelease", classify_bump("1.0.0-alpha", "1.0.0"));
}
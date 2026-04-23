//! Adversarial tests for Pmp.Semver — edge cases for parse_semver,
//! compare_semver, compare_prerelease, classify_bump.

import PUnit;
import Pmp.Semver;
inherit PUnit.TestCase;

// ── parse_semver ─────────────────────────────────────────────────────

void test_parse_trailing_dash() {
    // "1.2.3-" — dash present but empty prerelease: invalid per semver spec §9
    assert_equal(0, parse_semver("1.2.3-"));
}

void test_parse_empty_build_metadata() {
    // "1.2.3+" — empty build metadata: invalid per semver spec §10
    assert_equal(0, parse_semver("1.2.3+"));
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
    // Empty identifier between dots: invalid per semver spec §9
    assert_equal(0, parse_semver("1.2.3-alpha..beta"));
}

void test_parse_whitespace_prerelease() {
    // Tab in prerelease: not [0-9A-Za-z-], invalid per semver spec §9
    assert_equal(0, parse_semver("1.2.3-\t"));
}

void test_parse_unicode_prerelease() {
    // Unicode in prerelease: not [0-9A-Za-z-], invalid per semver spec §9
    assert_equal(0, parse_semver("1.2.3-\x03b1\x03b2"));
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
    // Partial versions rejected per strict semver spec §2 (requires X.Y.Z)
    assert_equal(0, parse_semver("1"));
    assert_equal(0, parse_semver("1.2"));
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
    // "1.0.0-alpha/beta" — slash not valid in prerelease per semver spec §9
    assert_equal(0, parse_semver("1.0.0-alpha/beta"));
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
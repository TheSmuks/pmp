//! Tests for Pmp.Semver — parse_semver, compare_semver, sort_tags_semver, classify_bump.

import PUnit;
import Semver;
inherit PUnit.TestCase;

// ── parse_semver ─────────────────────────────────────────────────────

void test_parse_standard() {
    mapping v = parse_semver("1.2.3");
    assert_not_null(v);
    assert_equal(1, v["major"]);
    assert_equal(2, v["minor"]);
    assert_equal(3, v["patch"]);
    assert_equal("", v["prerelease"]);
    assert_equal("1.2.3", v["original"]);
}

void test_parse_v_prefix() {
    mapping v = parse_semver("v1.2.3");
    assert_not_null(v);
    assert_equal(1, v["major"]);
    assert_equal(2, v["minor"]);
    assert_equal(3, v["patch"]);
}

void test_parse_uppercase_v_prefix() {
    mapping v = parse_semver("V2.0.0");
    assert_not_null(v);
    assert_equal(2, v["major"]);
}

void test_parse_prerelease() {
    mapping v = parse_semver("1.2.3-alpha");
    assert_not_null(v);
    assert_equal("alpha", v["prerelease"]);
}

void test_parse_prerelease_dotted() {
    mapping v = parse_semver("1.2.3-alpha.1");
    assert_not_null(v);
    assert_equal("alpha.1", v["prerelease"]);
}

void test_parse_build_metadata() {
    // Build metadata is stripped per semver spec
    mapping v = parse_semver("1.2.3+build");
    assert_not_null(v);
    assert_equal(3, v["patch"]);
    assert_equal("", v["prerelease"]);
}

void test_parse_prerelease_and_build() {
    mapping v = parse_semver("1.2.3-beta.2+build.123");
    assert_not_null(v);
    assert_equal("beta.2", v["prerelease"]);
    assert_equal("1.2.3-beta.2+build.123", v["original"]);
}

void test_parse_two_part_version() {
    // "1.2" — partial version rejected per strict semver spec §2
    assert_equal(0, parse_semver("1.2"));
}

void test_parse_single_part_version() {
    // "7" — partial version rejected per strict semver spec §2
    assert_equal(0, parse_semver("7"));
}

void test_parse_empty_string() {
    assert_equal(0, parse_semver(""));
}

void test_parse_zero_arg() {
    assert_equal(0, parse_semver(0));
}

void test_parse_non_semver() {
    assert_equal(0, parse_semver("not-a-version"));
}

void test_parse_partial_letters() {
    assert_equal(0, parse_semver("1.2.x"));
}

void test_parse_leading_zeros() {
    // "01.2.3" — leading zeros rejected per semver spec §2
    assert_equal(0, parse_semver("01.2.3"));
}

void test_parse_trailing_dot() {
    // "1.2." — empty part after dot
    assert_equal(0, parse_semver("1.2."));
}

// ── compare_semver ───────────────────────────────────────────────────

void test_compare_ordering_major() {
    mapping a = parse_semver("1.0.0");
    mapping b = parse_semver("2.0.0");
    assert_equal(-1, compare_semver(a, b));
    assert_equal(1, compare_semver(b, a));
}

void test_compare_ordering_minor() {
    mapping a = parse_semver("1.1.0");
    mapping b = parse_semver("1.2.0");
    assert_equal(-1, compare_semver(a, b));
}

void test_compare_ordering_patch() {
    mapping a = parse_semver("1.0.1");
    mapping b = parse_semver("1.0.2");
    assert_equal(-1, compare_semver(a, b));
}

void test_compare_equality() {
    mapping a = parse_semver("1.0.0");
    mapping b = parse_semver("1.0.0");
    assert_equal(0, compare_semver(a, b));
}

void test_compare_equality_v_prefix() {
    mapping a = parse_semver("v1.0.0");
    mapping b = parse_semver("1.0.0");
    assert_equal(0, compare_semver(a, b));
}

void test_compare_prerelease_less_than_release() {
    mapping a = parse_semver("1.0.0-alpha");
    mapping b = parse_semver("1.0.0");
    assert_equal(-1, compare_semver(a, b));
}

void test_compare_prerelease_numeric_less_than_alpha() {
    mapping a = parse_semver("1.0.0-1");
    mapping b = parse_semver("1.0.0-alpha");
    assert_equal(-1, compare_semver(a, b));
}

void test_compare_both_unparseable() {
    assert_equal(0, compare_semver(0, 0));
}

void test_compare_left_unparseable() {
    mapping b = parse_semver("1.0.0");
    assert_equal(-1, compare_semver(0, b));
}

void test_compare_right_unparseable() {
    mapping a = parse_semver("1.0.0");
    assert_equal(1, compare_semver(a, 0));
}

// ── sort_tags_semver ─────────────────────────────────────────────────

void test_sort_highest_first() {
    array(string) sorted = sort_tags_semver(({"v1.0.0", "v2.0.0", "v1.5.0"}));
    assert_equal(({ "v2.0.0", "v1.5.0", "v1.0.0" }), sorted);
}

void test_sort_non_semver_last() {
    array(string) sorted = sort_tags_semver(({"not-a-tag", "v1.0.0", "v0.5.0"}));
    assert_equal("v1.0.0", sorted[0]);
    assert_equal("v0.5.0", sorted[1]);
    assert_equal("not-a-tag", sorted[2]);
}

void test_sort_empty_array() {
    assert_equal(({}), sort_tags_semver(({})));
}

void test_sort_single_element() {
    assert_equal(({"v1.0.0"}), sort_tags_semver(({"v1.0.0"})));
}

void test_sort_mixed_valid_and_invalid() {
    array(string) sorted = sort_tags_semver(
        ({"v0.1.0", "release", "v0.10.0", "v0.2.0"}));
    assert_equal("v0.10.0", sorted[0]);
    assert_equal("v0.2.0", sorted[1]);
    assert_equal("v0.1.0", sorted[2]);
    assert_equal("release", sorted[3]);
}

// ── classify_bump ────────────────────────────────────────────────────

void test_classify_major() {
    assert_equal("major", classify_bump("v1.0.0", "v2.0.0"));
}

void test_classify_minor() {
    assert_equal("minor", classify_bump("v1.0.0", "v1.1.0"));
}

void test_classify_patch() {
    assert_equal("patch", classify_bump("v1.0.0", "v1.0.1"));
}

void test_classify_prerelease_old() {
    assert_equal("prerelease", classify_bump("v1.0.0-alpha", "v1.0.0-beta"));
}

void test_classify_prerelease_new() {
    assert_equal("prerelease", classify_bump("v1.0.0", "v1.0.1-alpha"));
}

void test_classify_downgrade() {
    assert_equal("downgrade", classify_bump("v2.0.0", "v1.0.0"));
}

void test_classify_unknown_missing_old() {
    assert_equal("unknown", classify_bump(0, "v1.0.0"));
}

void test_classify_unknown_missing_new() {
    assert_equal("unknown", classify_bump("v1.0.0", 0));
}

void test_classify_unknown_both_unparseable() {
    assert_equal("unknown", classify_bump("foo", "bar"));
}

void test_classify_same_version() {
    // Equal versions return "none"
    assert_equal("none", classify_bump("v1.0.0", "v1.0.0"));
}

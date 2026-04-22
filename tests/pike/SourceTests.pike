//! Tests for Pmp.Source — detect_source_type, source_to_name/version/domain/repo_path/strip_version.

import PUnit;
import Pmp.Source;
inherit PUnit.TestCase;

// ── detect_source_type ───────────────────────────────────────────────

void test_detect_local_relative() {
    assert_equal("local", detect_source_type("./my-module"));
}

void test_detect_local_absolute() {
    assert_equal("local", detect_source_type("/home/user/my-module"));
}

void test_detect_github() {
    assert_equal("github", detect_source_type("github.com/owner/repo"));
}

void test_detect_github_with_version() {
    assert_equal("github", detect_source_type("github.com/owner/repo#v1.0.0"));
}

void test_detect_gitlab() {
    assert_equal("gitlab", detect_source_type("gitlab.com/owner/repo"));
}

void test_detect_selfhosted() {
    assert_equal("selfhosted", detect_source_type("git.example.com/owner/repo"));
}

// ── source_to_name ───────────────────────────────────────────────────

void test_name_from_github() {
    assert_equal("repo", source_to_name("github.com/owner/repo"));
}

void test_name_with_version() {
    assert_equal("repo", source_to_name("github.com/owner/repo#v1.0.0"));
}

void test_name_deep_path() {
    assert_equal("mymod", source_to_name("git.example.com/group/sub/mymod"));
}

// ── source_to_version ────────────────────────────────────────────────

void test_version_from_tagged_source() {
    assert_equal("v1.0.0", source_to_version("github.com/owner/repo#v1.0.0"));
}

void test_version_empty_when_no_tag() {
    assert_equal("", source_to_version("github.com/owner/repo"));
}

void test_version_preserves_hash_in_tag() {
    assert_equal("v1.0.0-beta", source_to_version("github.com/owner/repo#v1.0.0-beta"));
}

// ── source_strip_version ─────────────────────────────────────────────

void test_strip_version_with_tag() {
    assert_equal("github.com/owner/repo",
                 source_strip_version("github.com/owner/repo#v1.0.0"));
}

void test_strip_version_no_tag() {
    assert_equal("github.com/owner/repo",
                 source_strip_version("github.com/owner/repo"));
}

// ── source_to_domain ─────────────────────────────────────────────────

void test_domain_github() {
    assert_equal("github.com", source_to_domain("github.com/owner/repo"));
}

void test_domain_gitlab() {
    assert_equal("gitlab.com", source_to_domain("gitlab.com/owner/repo#v2.0.0"));
}

void test_domain_selfhosted() {
    assert_equal("git.example.com", source_to_domain("git.example.com/team/mod"));
}

// ── source_to_repo_path ──────────────────────────────────────────────

void test_repo_path_basic() {
    assert_equal("owner/repo", source_to_repo_path("github.com/owner/repo"));
}

void test_repo_path_with_version() {
    assert_equal("owner/repo",
                 source_to_repo_path("github.com/owner/repo#v1.0.0"));
}

void test_repo_path_deep() {
    assert_equal("group/sub/mymod",
                 source_to_repo_path("git.example.com/group/sub/mymod"));
}

void test_repo_path_short() {
    // Only domain, no owner/repo
    assert_equal("", source_to_repo_path("github.com"));
}

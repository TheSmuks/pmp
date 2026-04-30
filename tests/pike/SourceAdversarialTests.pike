//! Adversarial tests for Pmp.Source — edge cases around URL schemes,
//! SCP-style git URLs, trailing suffixes, multi-segment paths, and
//! version tag parsing.

import PUnit;
import Source;
import Helpers;
inherit PUnit.TestCase;

// ── detect_source_type: scheme & format variations ───────────────────

void test_detect_github() {
    assert_equal("github",
        detect_source_type("https://github.com/owner/repo"));
}

void test_detect_gitlab() {
    assert_equal("gitlab",
        detect_source_type("https://gitlab.com/owner/repo"));
}

void test_detect_selfhosted() {
    assert_equal("selfhosted",
        detect_source_type("https://git.example.com/owner/repo"));
}

void test_detect_local_relative() {
    assert_equal("local", detect_source_type("./local/path"));
}

void test_detect_local_absolute() {
    assert_equal("local", detect_source_type("/absolute/path"));
}

void test_detect_ssh_format() {
    // ssh:// scheme with git@ user prefix
    assert_equal("github",
        detect_source_type("ssh://git@github.com/owner/repo"));
}

void test_detect_with_git_suffix() {
    assert_equal("github",
        detect_source_type("https://github.com/owner/repo.git"));
}

void test_detect_with_version() {
    assert_equal("github",
        detect_source_type("https://github.com/owner/repo#v1.0.0"));
}

// ── source_to_name: edge cases ───────────────────────────────────────

void test_name_github() {
    // Hyphens are sanitized to underscores for valid Pike module names
    assert_equal("my_mod",
        source_to_name("https://github.com/owner/my-mod"));
}

void test_name_with_version() {
    // Version fragment must be stripped before extracting name
    assert_equal("repo",
        source_to_name("https://github.com/owner/repo#v1.0"));
}

void test_name_local() {
    assert_equal("path", source_to_name("./some/path"));
}

// ── source_to_version: hash parsing ──────────────────────────────────

void test_version_with_hash() {
    assert_equal("v1.2.3",
        source_to_version("https://github.com/owner/repo#v1.2.3"));
}

void test_version_no_hash() {
    assert_equal("",
        source_to_version("https://github.com/owner/repo"));
}

void test_version_double_hash() {
    // Second # is preserved inside the tag
    assert_equal("v1#extra",
        source_to_version("src#v1#extra"));
}

// ── source_to_domain: extraction ─────────────────────────────────────

void test_domain_github() {
    assert_equal("github.com",
        source_to_domain("https://github.com/owner/repo"));
}

void test_domain_gitlab() {
    assert_equal("gitlab.com",
        source_to_domain("https://gitlab.com/owner/repo"));
}

// ── source_to_repo_path: path segments ───────────────────────────────

void test_repo_path() {
    assert_equal("owner/repo",
        source_to_repo_path("https://github.com/owner/repo"));
}

void test_repo_path_deep() {
    // Deep nesting: all segments after domain
    assert_equal("org/team/repo",
        source_to_repo_path("https://github.com/org/team/repo"));
}

void test_repo_path_with_git_suffix() {
    assert_equal("owner/repo",
        source_to_repo_path("https://github.com/owner/repo.git"));
}

void test_repo_path_ssh_scheme() {
    assert_equal("owner/repo",
        source_to_repo_path("ssh://git@github.com/owner/repo"));
}

// ── source_to_name: scheme stripping ─────────────────────────────────

void test_name_git_scheme() {
    assert_equal("repo",
        source_to_name("git://github.com/owner/repo"));
}

void test_name_ssh_scheme() {
    assert_equal("repo",
        source_to_name("ssh://git@github.com/owner/repo"));
}

void test_name_http_scheme() {
    assert_equal("repo",
        source_to_name("http://github.com/owner/repo"));
}

// ── validate_version_tag: security edge cases ────────────────────────
// These call die() so must be tested in subprocesses.

protected int run_subprocess(string code) {
    mapping result = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-M", combine_path(getcwd(), "bin/core"),
        "-M", combine_path(getcwd(), "bin/transport"),
        "-M", combine_path(getcwd(), "bin/store"),
        "-M", combine_path(getcwd(), "bin/project"),
        "-M", combine_path(getcwd(), "bin/commands"),
        "-e", code
    }));
    return result->exitcode;
}

void test_validate_tag_rejects_slash() {
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"foo/bar\");"
    );
    assert_true(code != 0, "tag with / should have died");
}

void test_validate_tag_rejects_backslash() {
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"foo\\\\bar\");"
    );
    assert_true(code != 0, "tag with \\ should have died");
}

void test_validate_tag_rejects_dotdot() {
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"..\\\/..\");"
    );
    assert_true(code != 0, "tag with .. should have died");
}

void test_validate_tag_rejects_semicolon() {
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"v1;rm -rf /\");"
    );
    assert_true(code != 0, "tag with ; should have died");
}

void test_validate_tag_allows_valid_semver() {
    // Valid semver tags must not die
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"v1.2.3\"); "
        "validate_version_tag(\"0.1.0-alpha.1\"); "
        "validate_version_tag(\"2.0.0-rc.1+build.123\");"
    );
    assert_equal(0, code);
}

void test_validate_tag_empty_is_allowed() {
    // Empty tag is allowed (no version specified)
    int code = run_subprocess(
        "import Source; "
        "validate_version_tag(\"\");"
    );
    assert_equal(0, code);
}

// ── source_to_repo_path: graceful on invalid format ──────────────────

void test_repo_path_short_returns_empty() {
    // Only domain — should return empty string, not die
    assert_equal("", source_to_repo_path("github.com"));
}


// ── source_strip_version: not covered by existing tests ────────────

void test_strip_version_with_tag() {
    assert_equal("github.com/owner/repo",
                 source_strip_version("github.com/owner/repo#v1.0.0"));
}

void test_strip_version_no_tag() {
    assert_equal("github.com/owner/repo",
                 source_strip_version("github.com/owner/repo"));
}

// ── bare-format URLs (no scheme prefix) ─────────────────────────────

void test_detect_github_bare_format() {
    // Bare hostname without scheme
    assert_equal("github", detect_source_type("github.com/owner/repo"));
}

void test_detect_github_bare_with_version() {
    assert_equal("github",
        detect_source_type("github.com/owner/repo#v1.0.0"));
}

void test_name_deep_path_bare() {
    // Deep nesting without scheme
    assert_equal("mymod",
        source_to_name("git.example.com/group/sub/mymod"));
}

void test_version_preserves_prerelease() {
    // Prerelease suffix in version tag
    assert_equal("v1.0.0-beta",
        source_to_version("github.com/owner/repo#v1.0.0-beta"));
}

void test_domain_selfhosted_bare() {
    assert_equal("git.example.com",
        source_to_domain("git.example.com/team/mod"));
}

void test_repo_path_bare_with_version() {
    assert_equal("owner/repo",
        source_to_repo_path("github.com/owner/repo#v1.0.0"));
}
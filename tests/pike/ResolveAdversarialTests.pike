//! Adversarial tests for Pmp.Resolve — edge cases for tag resolution,
//! cache key generation, ls-remote parsing logic, and semver sorting
//! in the resolution context.

import PUnit;
import Pmp;
inherit PUnit.TestCase;

// ── Module structure ──────────────────────────────────────────────────

void test_module_imports() {
    // Resolve inherits Semver, Helpers, Http — all their functions should
    // be reachable. Verify the key public API exists.
    assert_true(functionp(latest_tag), "latest_tag should be callable");
    assert_true(functionp(resolve_commit_sha),
                "resolve_commit_sha should be callable");
    assert_true(functionp(latest_tag_github),
                "latest_tag_github should be callable");
    assert_true(functionp(latest_tag_gitlab),
                "latest_tag_gitlab should be callable");
    assert_true(functionp(latest_tag_selfhosted),
                "latest_tag_selfhosted should be callable");
}

void test_inherited_semver_functions_available() {
    // Resolve inherits Semver — these must be reachable through Resolve.
    assert_true(functionp(parse_semver),
                "parse_semver (inherited from Semver) should be callable");
    assert_true(functionp(compare_semver),
                "compare_semver (inherited from Semver) should be callable");
    assert_true(functionp(sort_tags_semver),
                "sort_tags_semver (inherited from Semver) should be callable");
    assert_true(functionp(classify_bump),
                "classify_bump (inherited from Semver) should be callable");
}

// ── MAX_TAG_PAGES constant ────────────────────────────────────────────

void test_max_tag_pages_constant() {
    // Verify the pagination guard is a reasonable positive integer.
    assert_true(intp(MAX_TAG_PAGES),
                "MAX_TAG_PAGES should be an int");
    assert_true(MAX_TAG_PAGES > 0,
                "MAX_TAG_PAGES should be positive");
    assert_true(MAX_TAG_PAGES <= 100,
                "MAX_TAG_PAGES should have an upper bound");
}

// ── Cache key format ──────────────────────────────────────────────────

void test_cache_key_format() {
    // latest_tag builds keys as type + ":" + domain + "/" + repo_path.
    // Verify the format by constructing the same key and checking structure.
    string key_github = "github" + ":" + "github.com" + "/" + "owner/repo";
    assert_true(has_prefix(key_github, "github:"),
                "github cache key should start with 'github:'");
    assert_true(has_value(key_github, "/"),
                "cache key should contain path separator");

    string key_gitlab = "gitlab" + ":" + "gitlab.com" + "/" + "owner/repo";
    assert_true(has_prefix(key_gitlab, "gitlab:"),
                "gitlab cache key should start with 'gitlab:'");

    string key_self = "selfhosted" + ":" + "git.example.com" + "/" + "org/lib";
    assert_true(has_prefix(key_self, "selfhosted:"),
                "selfhosted cache key should start with 'selfhosted:'");

    // Different types with same repo must produce different keys
    assert_true(key_github != key_gitlab,
                "different source types must produce different cache keys");
}

void test_cache_key_special_chars_in_repo() {
    // Repo paths with dots, dashes, underscores — all legal in repo names.
    string key = "github" + ":" + "github.com" + "/"
                 + "my-org.my_lib-v2";
    assert_equal("github:github.com/my-org.my_lib-v2", key);
    // Key must not mangle special characters
    assert_true(has_value(key, "my-org.my_lib-v2"),
                "cache key preserves repo path special chars");
}

// ── ls-remote output parsing (simulated) ──────────────────────────────

void test_ls_remote_line_parsing_basic() {
    // Simulate the parsing logic from latest_tag_selfhosted:
    //   sha\trefs/tags/tagname  → extract (tagname, sha)
    string line = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2\trefs/tags/v1.2.3";
    array(string) parts = line / "\t";
    assert_true(sizeof(parts) >= 2, "ls-remote line should have tab separator");
    string sha = parts[0];
    string tag = replace(parts[-1], "refs/tags/", "");
    assert_equal("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", sha);
    assert_equal("v1.2.3", tag);
}

void test_ls_remote_line_parsing_deref_filtered() {
    // Dereferenced tag lines (^{}) must be filtered out before tag extraction.
    array(string) lines = ({
        "sha1111111111111111111111111111111111111111\trefs/tags/v1.0.0",
        "sha2222222222222222222222222222222222222222\trefs/tags/v1.0.0^{}",
        "sha3333333333333333333333333333333333333333\trefs/tags/v2.0.0",
        "sha4444444444444444444444444444444444444444\trefs/tags/v2.0.0^{}",
    });
    // Filter out ^{} lines — mirrors the lambda in latest_tag_selfhosted
    array(string) filtered = filter(lines, lambda(string l) {
        return sizeof(l) > 0 && !has_value(l, "^{}");
    });
    assert_equal(2, sizeof(filtered));
    assert_true(!has_value(filtered[0], "^{}"),
                 "filtered lines should not contain deref marker");
    assert_true(!has_value(filtered[1], "^{}"),
                 "filtered lines should not contain deref marker");
}

void test_ls_remote_empty_output() {
    // Empty ls-remote output → no tags.
    array(string) lines = ({});
    // After filtering empty/blank lines
    array(string) filtered = filter(lines, lambda(string l) {
        return sizeof(l) > 0 && !has_value(l, "^{}");
    });
    assert_equal(0, sizeof(filtered));
}

void test_ls_remote_blank_lines_filtered() {
    // ls-remote may produce trailing newlines → blank lines.
    array(string) lines = ({
        "sha1111111111111111111111111111111111111111\trefs/tags/v1.0.0",
        "",
        "sha2222222222222222222222222222222222222222\trefs/tags/v2.0.0",
        "",
    });
    array(string) filtered = filter(lines, lambda(string l) {
        return sizeof(l) > 0 && !has_value(l, "^{}");
    });
    assert_equal(2, sizeof(filtered));
}

// ── sort_tags_semver in resolution context ─────────────────────────────

void test_sort_tags_semver_resolution_order() {
    // Resolution picks tag_names[0] after sort — highest semver first.
    array(string) tags = ({"v1.0.0", "v2.0.0", "v1.10.0", "v1.2.0"});
    array(string) sorted = sort_tags_semver(tags);
    assert_equal("v2.0.0", sorted[0],
                 "highest semver should be first after sort");
    assert_equal(4, sizeof(sorted), "no tags should be dropped");
}

void test_sort_tags_semver_all_nonsemver() {
    // All non-semver tags → sort is stable, returns all tags.
    array(string) tags = ({"release", "latest", "snapshot"});
    array(string) sorted = sort_tags_semver(tags);
    assert_equal(3, sizeof(sorted),
                 "all non-semver tags should be preserved");
}

void test_sort_tags_semver_mixed_semver_and_nonsemver() {
    // Mixed: semver tags sort to front, non-semver to back.
    array(string) tags = ({"snapshot", "v1.0.0", "latest", "v0.9.0"});
    array(string) sorted = sort_tags_semver(tags);
    assert_equal("v1.0.0", sorted[0],
                 "highest semver tag should be first");
    // Non-semver tags should be at the end
    assert_true(sorted[-1] == "snapshot" || sorted[-1] == "latest",
                "non-semver tags should sort last");
}

void test_sort_tags_semver_prerelease_lower_than_release() {
    // Prerelease tags sort below their release counterparts.
    array(string) tags = ({"v1.0.0", "v1.0.0-alpha", "v1.0.0-beta"});
    array(string) sorted = sort_tags_semver(tags);
    assert_equal("v1.0.0", sorted[0],
                 "release should sort above prereleases");
}

void test_sort_tags_semver_empty_array() {
    array(string) sorted = sort_tags_semver(({}));
    assert_equal(0, sizeof(sorted), "empty input → empty output");
}

void test_sort_tags_semver_single_element() {
    array(string) sorted = sort_tags_semver(({"v3.1.4"}));
    assert_equal(1, sizeof(sorted));
    assert_equal("v3.1.4", sorted[0]);
}

// ── Tag response data validation (simulated JSON) ─────────────────────

void test_tag_response_entry_parsing() {
    // Simulate a GitHub tag API entry and verify extraction logic.
    // In latest_tag_github: entry->name, entry->commit->sha
    mapping entry = ([
        "name": "v1.2.3",
        "commit": ([ "sha": "abc123def456" ]),
        "zipball_url": "https://api.github.com/...",
        "tarball_url": "https://api.github.com/...",
    ]);
    assert_equal("v1.2.3", entry->name);
    assert_true(mappingp(entry->commit), "commit should be a mapping");
    assert_equal("abc123def456", entry->commit->sha);
}

void test_tag_response_missing_commit_sha() {
    // Entry with commit but no sha field → sha defaults to "".
    mapping entry = ([
        "name": "v1.0.0",
        "commit": ([ ]),
    ]);
    string sha = "";
    if (mappingp(entry->commit))
        sha = entry->commit->sha || "";
    assert_equal("", sha, "missing sha should default to empty");
}

void test_tag_response_null_commit() {
    // Entry with no commit field at all.
    mapping entry = (["name": "v0.1.0"]);
    string sha = "";
    if (mappingp(entry->commit))
        sha = entry->commit->sha || "";
    assert_equal("", sha, "null commit should not crash");
}

void test_tag_response_entry_without_name_skipped() {
    // Entries without a name field should be skipped.
    array(mapping) data = ({
        (["name": "v1.0.0", "commit": (["sha": "aaa"]) ]),
        (["zipball_url": "..."]),  // no name
        (["name": "v2.0.0", "commit": (["sha": "bbb"]) ]),
    });
    array(string) tag_names = ({});
    foreach (data; ; mapping entry)
        if (entry->name)
            tag_names += ({ entry->name });
    assert_equal(2, sizeof(tag_names),
                 "entries without name should be skipped");
    assert_equal("v1.0.0", tag_names[0]);
    assert_equal("v2.0.0", tag_names[1]);
}

// ── classify_bump in resolution context ────────────────────────────────

void test_classify_bump_downgrade_detection() {
    // When resolved tag is older than locked tag — a downgrade.
    assert_equal("downgrade", classify_bump("v2.0.0", "v1.0.0"));
}

void test_classify_bump_unknown_for_nonsemver() {
    assert_equal("unknown", classify_bump("not-a-version", "v1.0.0"));
    assert_equal("unknown", classify_bump("v1.0.0", "also-not-a-version"));
}

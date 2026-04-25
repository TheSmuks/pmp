//! Adversarial tests for Pmp.Install — edge cases for install orchestrators.
//! Tests pure functions: print_update_summary, merge_lock_entries,
//! and verifies structural correctness of error-handling paths.

import PUnit;
import Pmp;
inherit PUnit.TestCase;

// ── print_update_summary ────────────────────────────────────────────
// This function is pure (writes to stdout, no side effects beyond that).
// We wrap calls in catch to verify no crashes.

void test_update_summary_empty_arrays() {
    mixed err = catch { print_update_summary(({}), ({})); };
    assert_false(!!err, "empty arrays should not crash");
}

void test_update_summary_identical_entries() {
    array old = ({ ({ "mod1", "github.com/u/r", "v1.0.0", "sha1", "hash1" }) });
    array nw  = ({ ({ "mod1", "github.com/u/r", "v1.0.0", "sha1", "hash1" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "identical entries should not crash");
}

void test_update_summary_major_bump() {
    array old = ({ ({ "mylib", "github.com/u/mylib", "v1.5.0", "s1", "h1" }) });
    array nw  = ({ ({ "mylib", "github.com/u/mylib", "v2.0.0", "s2", "h2" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "major bump should not crash");
}

void test_update_summary_minor_bump() {
    array old = ({ ({ "pkg", "src", "v1.2.0", "sha", "h" }) });
    array nw  = ({ ({ "pkg", "src", "v1.3.0", "sha2", "h2" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "minor bump should not crash");
}

void test_update_summary_patch_bump() {
    array old = ({ ({ "pkg", "src", "v1.2.3", "sha", "h" }) });
    array nw  = ({ ({ "pkg", "src", "v1.2.4", "sha2", "h2" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "patch bump should not crash");
}

void test_update_summary_old_empty_new_has_entries() {
    array old = ({});
    array nw  = ({ ({ "newmod", "src", "v0.1.0", "sha", "h" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "old empty / new non-empty should not crash");
}

void test_update_summary_new_module_not_in_old() {
    array old = ({ ({ "existing", "src", "v1.0.0", "s", "h" }) });
    array nw  = ({
        ({ "existing", "src", "v1.0.0", "s", "h" }),
        ({ "brand_new", "src2", "v3.0.0", "s2", "h2" }),
    });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "new module absent from old should not crash");
}

void test_update_summary_dash_versions_skipped() {
    // Versions with "-" are local deps — should be skipped in comparison
    array old = ({ ({ "local_mod", "./path", "-", "sha", "h" }) });
    array nw  = ({ ({ "local_mod", "./path", "-", "sha", "h" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "dash version entries should not crash");
}

void test_update_summary_multiple_mixed() {
    array old = ({
        ({ "a", "src_a", "v1.0.0", "s1", "h1" }),
        ({ "b", "src_b", "v2.0.0", "s2", "h2" }),
        ({ "c", "src_c", "v3.0.0", "s3", "h3" }),
        ({ "d", "src_d", "-", "-", "-" }),
    });
    array nw = ({
        ({ "a", "src_a", "v1.1.0", "s1a", "h1a" }),   // minor
        ({ "b", "src_b", "v2.0.0", "s2", "h2" }),       // no change
        ({ "c", "src_c", "v4.0.0", "s3a", "h3a" }),     // major
        ({ "d", "src_d", "-", "-", "-" }),               // local unchanged
        ({ "e", "src_e", "v1.0.0", "s4", "h4" }),       // new
    });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "mixed update summary should not crash");
}

void test_update_summary_downgrade() {
    // New version is lower than old
    array old = ({ ({ "pkg", "src", "v2.0.0", "s1", "h1" }) });
    array nw  = ({ ({ "pkg", "src", "v1.0.0", "s2", "h2" }) });
    mixed err = catch { print_update_summary(old, nw); };
    assert_false(!!err, "downgrade should not crash");
}

// ── merge_lock_entries ──────────────────────────────────────────────
// Imported via Pmp (inherits Lockfile). These are pure functions.

void test_merge_lock_entries_empty_both() {
    array merged = merge_lock_entries(({}), ({}));
    assert_equal(0, sizeof(merged));
}

void test_merge_lock_entries_empty_existing() {
    array nw = ({ ({ "mod1", "src1", "v1", "sha1", "hash1" }) });
    array merged = merge_lock_entries(({}), nw);
    assert_equal(1, sizeof(merged));
    assert_equal("mod1", merged[0][0]);
}

void test_merge_lock_entries_empty_new() {
    array existing = ({ ({ "mod1", "src1", "v1", "sha1", "hash1" }) });
    array merged = merge_lock_entries(existing, ({}));
    assert_equal(1, sizeof(merged));
    assert_equal("mod1", merged[0][0]);
}

void test_merge_lock_entries_new_overrides() {
    array existing = ({
        ({ "shared", "old_src", "v1", "old_sha", "old_hash" }),
    });
    array nw = ({
        ({ "shared", "new_src", "v2", "new_sha", "new_hash" }),
    });
    array merged = merge_lock_entries(existing, nw);
    assert_equal(1, sizeof(merged));
    assert_equal("new_src", merged[0][1]);
    assert_equal("v2", merged[0][2]);
}

void test_merge_lock_entries_mixed_overlap() {
    array existing = ({
        ({ "keep", "s1", "v1", "sh1", "h1" }),
        ({ "replace", "s2", "v2", "sh2", "h2" }),
    });
    array nw = ({
        ({ "replace", "s2_new", "v3", "sh3", "h3" }),
        ({ "added", "s4", "v4", "sh4", "h4" }),
    });
    array merged = merge_lock_entries(existing, nw);
    assert_equal(3, sizeof(merged));
    // Build name map to verify
    mapping(string:array(string)) by_name = ([]);
    foreach (merged; ; array(string) e)
        by_name[e[0]] = e;
    assert_equal("s1", by_name["keep"][1]);
    assert_equal("s2_new", by_name["replace"][1]);
    assert_equal("s4", by_name["added"][1]);
}

void test_merge_lock_entries_duplicate_names_in_new() {
    // new_entries with same name — last wins after dedup
    array nw = ({
        ({ "dup", "first", "v1", "s1", "h1" }),
        ({ "dup", "second", "v2", "s2", "h2" }),
    });
    array merged = merge_lock_entries(({}), nw);
    assert_equal(1, sizeof(merged));
    assert_equal("second", merged[0][1]);
}

void test_merge_lock_entries_does_not_mutate_inputs() {
    array existing = ({ ({ "a", "sa", "v1", "sh1", "h1" }) });
    array nw = ({ ({ "b", "sb", "v2", "sh2", "h2" }) });
    merge_lock_entries(existing, nw);
    assert_equal(1, sizeof(existing));
    assert_equal("a", existing[0][0]);
    assert_equal(1, sizeof(nw));
    assert_equal("b", nw[0][0]);
}

void test_merge_lock_entries_empty_name_entries_skipped() {
    // Entries with empty names should be skipped
    array existing = ({
        ({ "", "s0", "v0", "sh0", "h0" }),
        ({ "valid", "s1", "v1", "sh1", "h1" }),
    });
    array nw = ({
        ({ "", "s2", "v2", "sh2", "h2" }),
    });
    array merged = merge_lock_entries(existing, nw);
    // Only "valid" survives from existing; empty-name entries are skipped
    assert_equal(1, sizeof(merged));
    assert_equal("valid", merged[0][0]);
}

void test_merge_lock_entries_large_scale() {
    array existing = ({});
    for (int i = 0; i < 200; i++)
        existing += ({ ({ "mod" + i, "s" + i, "v1", "sh" + i, "h" + i }) });

    array nw = ({});
    for (int i = 100; i < 300; i++)
        nw += ({ ({ "mod" + i, "s_new" + i, "v2", "sh_new" + i, "h_new" + i }) });

    array merged = merge_lock_entries(existing, nw);

    // 100 unique from existing (mod0..mod99) + 200 from new (mod100..mod299) = 300
    // Wait: new has mod100..mod299 = 200 entries. existing unique (not in new) = mod0..mod99 = 100.
    // Total: 100 + 200 = 300
    assert_equal(300, sizeof(merged));

    // Verify no duplicates
    multiset(string) seen = (<>);
    int dups = 0;
    foreach (merged; ; array(string) e) {
        if (seen[e[0]]) dups++;
        seen[e[0]] = 1;
    }
    assert_equal(0, dups);
}

// ── lockfile_add_entry (used heavily in Install) ───────────────────

void test_lockfile_add_entry_preserves_order() {
    array entries = ({});
    entries = lockfile_add_entry(entries, "z", "sz", "v1", "sh1", "h1");
    entries = lockfile_add_entry(entries, "a", "sa", "v2", "sh2", "h2");
    entries = lockfile_add_entry(entries, "m", "sm", "v3", "sh3", "h3");
    assert_equal(3, sizeof(entries));
    assert_equal("z", entries[0][0]);
    assert_equal("a", entries[1][0]);
    assert_equal("m", entries[2][0]);
}

void test_lockfile_add_entry_does_not_dedup() {
    // lockfile_add_entry appends — it does NOT deduplicate
    array entries = ({});
    entries = lockfile_add_entry(entries, "dup", "s1", "v1", "sh1", "h1");
    entries = lockfile_add_entry(entries, "dup", "s2", "v2", "sh2", "h2");
    assert_equal(2, sizeof(entries));
    assert_equal("s1", entries[0][1]);
    assert_equal("s2", entries[1][1]);
}

// ── classify_bump (used by print_update_summary) ───────────────────

void test_classify_bump_major() {
    assert_equal("major", classify_bump("v1.0.0", "v2.0.0"));
}

void test_classify_bump_minor() {
    assert_equal("minor", classify_bump("v1.0.0", "v1.1.0"));
}

void test_classify_bump_patch() {
    assert_equal("patch", classify_bump("v1.0.0", "v1.0.1"));
}

void test_classify_bump_downgrade() {
    assert_equal("downgrade", classify_bump("v2.0.0", "v1.0.0"));
}

void test_classify_bump_none() {
    assert_equal("none", classify_bump("v1.2.3", "v1.2.3"));
}

void test_classify_bump_null_args() {
    assert_equal("unknown", classify_bump(0, "v1.0.0"));
    assert_equal("unknown", classify_bump("v1.0.0", 0));
    assert_equal("unknown", classify_bump(0, 0));
}

void test_classify_bump_prerelease() {
    // Release -> prerelease is a "downgrade" (release > prerelease in semver)
    assert_equal("downgrade", classify_bump("v1.0.0", "v1.0.0-alpha"));
    assert_equal("prerelease", classify_bump("v1.0.0-alpha", "v1.0.0-beta"));
}

void test_classify_bump_invalid_tags() {
    assert_equal("unknown", classify_bump("not_a_version", "also_not"));
}

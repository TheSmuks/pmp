//! Adversarial tests for Pmp.Install — edge cases for install orchestrators.
//! Tests pure function: print_update_summary,

import PUnit;
import Pmp.Update;
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

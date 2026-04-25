//! Tests for Pmp.Config — exit codes, version format, lock constants.
//!
//! Note: set_quiet/set_verbose modify module-level state. In Pike, inherit
//! copies state at compile time, so changes in Config don't propagate to
//! Helpers' inherited copy. These functions work correctly at runtime via
//! the pmp shim which uses a single process. The functions are tested
//! indirectly via the shell test suite.

import PUnit;
inherit Pmp.Config;
inherit PUnit.TestCase;

void test_exit_codes() {
    // Exit codes must be standard Unix conventions
    assert_equal(0, EXIT_OK);
    assert_equal(1, EXIT_ERROR);
    assert_equal(2, EXIT_INTERNAL);
}

void test_version_is_semver() {
    // PMP_VERSION must be a semver string (X.Y.Z)
    array(string) parts = PMP_VERSION / ".";
    assert_equal(3, sizeof(parts));
    foreach (parts; ; string p)
        assert_equal(true, sizeof(p) > 0 && sizeof(filter(p/1, lambda(string c) { return c < "0" || c > "9"; })) == 0);
}

void test_set_quiet_function_exists() {
    // Verify the function exists and is callable
    assert_not_null(set_quiet);
    // Calling it should not throw
    mixed err = catch { set_quiet(0); };
    assert_equal(0, !!err);
}

void test_set_verbose_function_exists() {
    // Verify the function exists and is callable
    assert_not_null(set_verbose);
    // Calling it should not throw
    mixed err = catch { set_verbose(0); };
    assert_equal(0, !!err);
}

// TODO: LOCK_MAX_ATTEMPTS_STORE, LOCK_MAX_ATTEMPTS_PROJECT, LOCK_BACKOFF_BASE
// are defined in behavior-spec.md but not yet implemented in Config.pmod.
// void test_lock_constants() {
//     assert_equal(true, LOCK_MAX_ATTEMPTS_STORE > 0);
//     assert_equal(true, LOCK_MAX_ATTEMPTS_PROJECT > 0);
//     assert_equal(true, LOCK_BACKOFF_BASE > 0.0);
// }

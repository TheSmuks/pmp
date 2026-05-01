//! Tests for Pmp.Helpers shared state (getenv/putenv pattern).
//! Verifies that cleanup registry, store lock state, and project lock state
//! survive across module inheritance boundaries.

import PUnit;
import Pmp.Config;
import Pmp.Helpers;
inherit PUnit.TestCase;

protected string tmpdir;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-helpers-state-" + getpid());
    Stdio.mkdirhier(tmpdir);
    // Reset shared state before each test
    putenv("PMP_CLEANUP_DIRS", "");
    putenv("PMP_PROJECT_LOCK", "");
    putenv("PMP_STORE_LOCKED", "0");
    putenv("PMP_STORE_DIR_LOCK", "");
    putenv("PMP_CLEANED_UP", "0");
}

void teardown() {
    // Reset shared state after each test
    putenv("PMP_CLEANUP_DIRS", "");
    putenv("PMP_PROJECT_LOCK", "");
    putenv("PMP_STORE_LOCKED", "0");
    putenv("PMP_STORE_DIR_LOCK", "");
    putenv("PMP_CLEANED_UP", "0");
    if (tmpdir && Stdio.is_dir(tmpdir))
        Process.run(({"rm", "-rf", tmpdir}));
}

// ── register_cleanup_dir / unregister_cleanup_dir ──────────────────

void test_register_cleanup_dir_single() {
    string d = combine_path(tmpdir, "clean-me");
    register_cleanup_dir(d);
    // The env var should contain the path
    string env_val = getenv("PMP_CLEANUP_DIRS") || "";
    assert_equal(1, has_value(env_val, d));
}

void test_register_cleanup_dir_multiple() {
    string d1 = combine_path(tmpdir, "a");
    string d2 = combine_path(tmpdir, "b");
    register_cleanup_dir(d1);
    register_cleanup_dir(d2);
    string env_val = getenv("PMP_CLEANUP_DIRS") || "";
    assert_equal(1, has_value(env_val, d1));
    assert_equal(1, has_value(env_val, d2));
}

void test_register_cleanup_dir_no_duplicates() {
    string d = combine_path(tmpdir, "dup");
    register_cleanup_dir(d);
    register_cleanup_dir(d);
    string env_val = getenv("PMP_CLEANUP_DIRS") || "";
    // Should appear only once
    array(string) parts = env_val / "\x1e";
    int count = 0;
    foreach (parts; ; string p)
        if (p == d) count++;
    assert_equal(1, count);
}

void test_unregister_cleanup_dir() {
    string d1 = combine_path(tmpdir, "x");
    string d2 = combine_path(tmpdir, "y");
    register_cleanup_dir(d1);
    register_cleanup_dir(d2);
    unregister_cleanup_dir(d1);
    string env_val = getenv("PMP_CLEANUP_DIRS") || "";
    assert_equal(0, has_value(env_val / "\x1e", d1));
    assert_equal(1, has_value(env_val / "\x1e", d2));
}

// ── register_project_lock_path ──────────────────────────────────────

void test_register_project_lock_path() {
    string lock_path = "/tmp/test-project.lock";
    register_project_lock_path(lock_path);
    assert_equal(lock_path, getenv("PMP_PROJECT_LOCK"));
}

void test_register_project_lock_path_clear() {
    register_project_lock_path("/tmp/test.lock");
    register_project_lock_path("");
    assert_equal("", getenv("PMP_PROJECT_LOCK") || "");
}

// ── set_store_lock_state ────────────────────────────────────────────

void test_set_store_lock_state_locked() {
    set_store_lock_state(1, "/tmp/store");
    assert_equal("1", getenv("PMP_STORE_LOCKED"));
    assert_equal("/tmp/store", getenv("PMP_STORE_DIR_LOCK"));
}

void test_set_store_lock_state_unlocked() {
    set_store_lock_state(1, "/tmp/store");
    set_store_lock_state(0, "");
    assert_equal("0", getenv("PMP_STORE_LOCKED"));
    assert_equal("", getenv("PMP_STORE_DIR_LOCK") || "");
}

// ── run_cleanup integration ─────────────────────────────────────────

void test_run_cleanup_removes_temp_dirs() {
    string d = combine_path(tmpdir, "to-clean");
    Stdio.mkdirhier(d);
    // Write a file inside to verify removal
    Stdio.write_file(combine_path(d, "test.txt"), "data");
    register_cleanup_dir(d);
    run_cleanup();
    assert_equal(0, Stdio.is_dir(d));
}

void test_run_cleanup_clears_project_lock() {
    register_project_lock_path("/tmp/nonexistent.lock");
    run_cleanup();
    assert_equal("", getenv("PMP_PROJECT_LOCK") || "");
}

void test_run_cleanup_idempotent() {
    string d = combine_path(tmpdir, "idem");
    Stdio.mkdirhier(d);
    register_cleanup_dir(d);
    run_cleanup();
    // Second call should not crash or error
    run_cleanup();
    assert_equal(0, Stdio.is_dir(d));
}

// ── verbose/quiet state via getenv/putenv ────────────────────────────

void test_verbose_shared_across_modules() {
    // Import another module that inherits Config — same pattern
    // Setting verbose in one should be visible from the other
    set_verbose(1);
    assert_equal("1", getenv("PMP_VERBOSE"));
    set_verbose(0);
    assert_equal("0", getenv("PMP_VERBOSE"));
}

void test_quiet_shared_across_modules() {
    set_quiet(1);
    assert_equal("1", getenv("PMP_QUIET"));
    set_quiet(0);
    assert_equal("0", getenv("PMP_QUIET"));
}

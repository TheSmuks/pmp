//! Tests for Pmp.Lockfile pure functions — lockfile_add_entry, merge_lock_entries, lockfile_has_dep.

import PUnit;
import Pmp.Lockfile;
inherit PUnit.TestCase;

// ── lockfile_add_entry ───────────────────────────────────────────────

void test_add_entry_appends() {
    array(array(string)) entries = ({});
    entries = lockfile_add_entry(entries, "mod1", "github.com/o/r", "v1.0.0",
                                 "abc123", "sha256abc");
    assert_equal(1, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
    assert_equal("github.com/o/r", entries[0][1]);
    assert_equal("v1.0.0", entries[0][2]);
    assert_equal("abc123", entries[0][3]);
    assert_equal("sha256abc", entries[0][4]);
}

void test_add_entry_preserves_existing() {
    array(array(string)) entries = ({});
    entries = lockfile_add_entry(entries, "mod1", "github.com/o/r1", "v1.0.0",
                                 "aaa", "sha1");
    entries = lockfile_add_entry(entries, "mod2", "github.com/o/r2", "v2.0.0",
                                 "bbb", "sha2");
    assert_equal(2, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
    assert_equal("mod2", entries[1][0]);
}

void test_add_entry_returns_new_array() {
    array(array(string)) original = ({});
    array(array(string)) result = lockfile_add_entry(original, "m", "s", "t", "sh", "h");
    // Original should be unchanged (Pike arrays are reference types but += creates new)
    assert_equal(0, sizeof(original));
    assert_equal(1, sizeof(result));
}

// ── merge_lock_entries ───────────────────────────────────────────────

void test_merge_dedup_by_name() {
    array(array(string)) existing = ({
        ({"mod1", "github.com/o/r1", "v1.0.0", "aaa", "sha1"}),
    });
    array(array(string)) new_entries = ({
        ({"mod1", "github.com/o/r1", "v2.0.0", "bbb", "sha2"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(1, sizeof(merged));
    assert_equal("v2.0.0", merged[0][2]);
}

void test_merge_keeps_non_overlapping() {
    array(array(string)) existing = ({
        ({"mod1", "github.com/o/r1", "v1.0.0", "aaa", "sha1"}),
    });
    array(array(string)) new_entries = ({
        ({"mod2", "github.com/o/r2", "v2.0.0", "bbb", "sha2"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(2, sizeof(merged));
}

void test_merge_new_takes_priority() {
    array(array(string)) existing = ({
        ({"mod1", "github.com/o/r1", "v1.0.0", "aaa", "sha1"}),
        ({"mod2", "github.com/o/r2", "v2.0.0", "bbb", "sha2"}),
    });
    array(array(string)) new_entries = ({
        ({"mod1", "github.com/o/r1", "v3.0.0", "ccc", "sha3"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(2, sizeof(merged));
    // mod1 should be the new version
    foreach (merged; ; array(string) e)
        if (e[0] == "mod1")
            assert_equal("v3.0.0", e[2]);
}

void test_merge_empty_existing() {
    array(array(string)) existing = ({});
    array(array(string)) new_entries = ({
        ({"mod1", "github.com/o/r1", "v1.0.0", "aaa", "sha1"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(1, sizeof(merged));
}

void test_merge_empty_new() {
    array(array(string)) existing = ({
        ({"mod1", "github.com/o/r1", "v1.0.0", "aaa", "sha1"}),
    });
    array(array(string)) new_entries = ({});
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(1, sizeof(merged));
}

// ── lockfile_has_dep ─────────────────────────────────────────────────
// Note: lockfile_has_dep reads from disk, so we create a temp lockfile.

protected string tmpdir;
protected string lockfile_path;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-lockfile-" + getpid());
    Stdio.mkdirhier(tmpdir);
    lockfile_path = combine_path(tmpdir, "pike.lock");
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir)) {
        // Clean up temp dir
        Process.run(({"rm", "-rf", tmpdir}));
    }
}

void write_temp_lockfile(array(array(string)) entries) {
    String.Buffer buf = String.Buffer();
    foreach (entries; ; array(string) entry)
        buf->add(entry[0] + "\t" + entry[1] + "\t" + entry[2]
                 + "\t" + entry[3] + "\t" + entry[4] + "\n");
    Stdio.write_file(lockfile_path, buf->get());
}

void test_has_dep_name_match() {
    write_temp_lockfile(({
        ({"PUnit", "github.com/TheSmuks/punit-tests", "v1.2.0", "abc", "sha1"}),
    }));
    assert_equal(1, lockfile_has_dep("PUnit", lockfile_path));
}

void test_has_dep_name_miss() {
    write_temp_lockfile(({
        ({"PUnit", "github.com/TheSmuks/punit-tests", "v1.2.0", "abc", "sha1"}),
    }));
    assert_equal(0, lockfile_has_dep("OtherMod", lockfile_path));
}

void test_has_dep_source_match() {
    write_temp_lockfile(({
        ({"PUnit", "github.com/TheSmuks/punit-tests", "v1.2.0", "abc", "sha1"}),
    }));
    assert_equal(1, lockfile_has_dep("PUnit", lockfile_path,
                                      "github.com/TheSmuks/punit-tests"));
}

void test_has_dep_source_mismatch() {
    write_temp_lockfile(({
        ({"PUnit", "github.com/TheSmuks/punit-tests", "v1.2.0", "abc", "sha1"}),
    }));
    assert_equal(0, lockfile_has_dep("PUnit", lockfile_path,
                                      "github.com/other/repo"));
}

void test_has_dep_empty_lockfile() {
    // No lockfile at all
    assert_equal(0, lockfile_has_dep("PUnit", lockfile_path));
}

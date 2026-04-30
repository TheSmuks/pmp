//! Adversarial tests for Pmp.Lockfile — edge cases and boundary conditions.

import PUnit;
import Lockfile;
inherit PUnit.TestCase;

// ── lockfile_add_entry ───────────────────────────────────────────────

void test_add_entry_empty_array() {
    array(array(string)) entries = ({});
    entries = lockfile_add_entry(entries, "foo", "src", "v1", "abc", "hash");
    assert_equal(1, sizeof(entries));
    assert_equal("foo", entries[0][0]);
    assert_equal("src", entries[0][1]);
    assert_equal("v1", entries[0][2]);
    assert_equal("abc", entries[0][3]);
    assert_equal("hash", entries[0][4]);
}

void test_add_entry_multiple() {
    array(array(string)) entries = ({});
    entries = lockfile_add_entry(entries, "a", "sa", "t1", "sha_a", "h_a");
    entries = lockfile_add_entry(entries, "b", "sb", "t2", "sha_b", "h_b");
    entries = lockfile_add_entry(entries, "c", "sc", "t3", "sha_c", "h_c");
    assert_equal(3, sizeof(entries));
    // Verify all present and in order
    assert_equal("a", entries[0][0]);
    assert_equal("b", entries[1][0]);
    assert_equal("c", entries[2][0]);
    assert_equal("sa", entries[0][1]);
    assert_equal("sb", entries[1][1]);
    assert_equal("sc", entries[2][1]);
}

void test_add_entry_preserves_existing() {
    array(array(string)) original = ({
        ({"orig1", "s1", "t1", "sh1", "h1"}),
        ({"orig2", "s2", "t2", "sh2", "h2"}),
    });
    array(array(string)) result = lockfile_add_entry(original, "new", "sn", "tn", "shn", "hn");
    // Original untouched — Pike += creates a new array
    assert_equal(2, sizeof(original));
    assert_equal("orig1", original[0][0]);
    assert_equal("orig2", original[1][0]);
    // Result has all three
    assert_equal(3, sizeof(result));
    assert_equal("orig1", result[0][0]);
    assert_equal("orig2", result[1][0]);
    assert_equal("new", result[2][0]);
}

void test_add_entry_empty_name_dies() {
    // die() calls exit() which is uncatchable — test via subprocess.
    int code = run_subprocess(
        "import Lockfile; "
        "lockfile_add_entry(({}), \"\", \"src\", \"v1\", \"sha\", \"hash\");"
    );
    assert_true(code != 0, "empty name should have died");
}

// ── merge_lock_entries ───────────────────────────────────────────────

void test_merge_both_empty() {
    array(array(string)) merged = merge_lock_entries(({}), ({}));
    assert_equal(0, sizeof(merged));
}

void test_merge_new_replaces_existing() {
    array(array(string)) existing = ({
        ({"foo", "src1", "v1", "sha1", "h1"}),
    });
    array(array(string)) new_entries = ({
        ({"foo", "src2", "v2", "sha2", "h2"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(1, sizeof(merged));
    assert_equal("src2", merged[0][1]);
    assert_equal("v2", merged[0][2]);
}

void test_merge_keeps_non_overlapping() {
    array(array(string)) existing = ({
        ({"foo", "sf", "v1", "sh1", "h1"}),
    });
    array(array(string)) new_entries = ({
        ({"bar", "sb", "v2", "sh2", "h2"}),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    assert_equal(2, sizeof(merged));
    // Find both by name regardless of order
    multiset(string) names = (<>);
    foreach (merged; ; array(string) e)
        names[e[0]] = 1;
    assert_equal(1, names["foo"]);
    assert_equal(1, names["bar"]);
}

void test_merge_100_entries() {
    // Build 100 existing entries
    array(array(string)) existing = ({});
    for (int i = 0; i < 100; i++)
        existing += ({ ({"mod" + i, "s" + i, "v1", "sh" + i, "h" + i}) });
    // Build 50 new entries that overlap on names 50..99
    array(array(string)) new_entries = ({});
    for (int i = 50; i < 150; i++)
        new_entries += ({ ({"mod" + i, "s_new" + i, "v2", "sh_new" + i, "h_new" + i}) });

    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    // 50 unique from existing (mod0..mod49) + 100 from new (mod50..mod149) = 150
    assert_equal(150, sizeof(merged));

    // Verify no duplicates by name
    multiset(string) seen = (<>);
    int duplicates = 0;
    foreach (merged; ; array(string) e) {
        if (seen[e[0]]) duplicates++;
        seen[e[0]] = 1;
    }
    assert_equal(0, duplicates);

    // Verify new entries won for overlapping names (mod50..mod99 have "s_new")
    foreach (merged; ; array(string) e)
        if (has_prefix(e[0], "mod") && (int)(e[0][3..]) >= 50 && (int)(e[0][3..]) < 100)
            assert_equal(1, has_prefix(e[1], "s_new"));
}

void test_merge_does_not_mutate_inputs() {
    array(array(string)) existing = ({
        ({"a", "sa", "v1", "sh1", "h1"}),
    });
    array(array(string)) new_entries = ({
        ({"b", "sb", "v2", "sh2", "h2"}),
    });
    merge_lock_entries(existing, new_entries);
    // Inputs unchanged
    assert_equal(1, sizeof(existing));
    assert_equal("a", existing[0][0]);
    assert_equal(1, sizeof(new_entries));
    assert_equal("b", new_entries[0][0]);
}
void test_merge_lock_entries_duplicates_in_new() {
    // new_entries with duplicate names — last wins
    array(array(string)) existing = ({});
    array(array(string)) new_entries = ({
        ({ "mod1", "source1", "v1", "sha1", "hash1" }),
        ({ "mod1", "source2", "v2", "sha2", "hash2" }),
    });
    array(array(string)) merged = merge_lock_entries(existing, new_entries);
    // Should have exactly 1 entry for mod1 (deduped)
    assert_equal(1, sizeof(merged));
    // Last occurrence wins
    assert_equal("source2", merged[0][1]);
}

void test_merge_lock_entries_empty_both() {
    array(array(string)) merged = merge_lock_entries(({}), ({}));
    assert_equal(0, sizeof(merged));
}

void test_merge_lock_entries_empty_existing() {
    array(array(string)) new_entries = ({
        ({ "mod1", "source1", "v1", "sha1", "hash1" }),
    });
    array(array(string)) merged = merge_lock_entries(({}), new_entries);
    assert_equal(1, sizeof(merged));
}


// die() calls exit() which is uncatchable — test in subprocess.
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
// ── lockfile_has_dep ─────────────────────────────────────────────────
// lockfile_has_dep reads from disk, so we create temp lockfiles.

protected string tmpdir;
protected string lockfile_path;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-lockfile-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
    lockfile_path = combine_path(tmpdir, "pike.lock");
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir))
        Process.run(({"rm", "-rf", tmpdir}));
}

void write_temp_lockfile(array(array(string)) entries) {
    String.Buffer buf = String.Buffer();
    buf->add("# pmp lockfile v1 — DO NOT EDIT\n");
    buf->add("# name\tsource\ttag\tcommit_sha\tcontent_sha256\n");
    foreach (entries; ; array(string) entry)
        buf->add(entry[0] + "\t" + entry[1] + "\t" + entry[2]
                 + "\t" + entry[3] + "\t" + entry[4] + "\n");
    Stdio.write_file(lockfile_path, buf->get());
}

void test_has_dep_empty_lockfile() {
    // No lockfile exists at the path
    assert_equal(0, lockfile_has_dep("foo", lockfile_path));
}

void test_has_dep_substring() {
    // Exact match required — "foo" must NOT match "foobar"
    write_temp_lockfile(({
        ({"foobar", "github.com/o/r", "v1", "sha", "hash"}),
    }));
    assert_equal(0, lockfile_has_dep("foo", lockfile_path));
    assert_equal(0, lockfile_has_dep("bar", lockfile_path));
    assert_equal(0, lockfile_has_dep("ooba", lockfile_path));
    // But full name matches
    assert_equal(1, lockfile_has_dep("foobar", lockfile_path));
}

void test_has_dep_with_source_match() {
    write_temp_lockfile(({
        ({"mymod", "github.com/o/r1", "v1", "sha1", "h1"}),
    }));
    assert_equal(1, lockfile_has_dep("mymod", lockfile_path,
                                      "github.com/o/r1"));
    assert_equal(0, lockfile_has_dep("mymod", lockfile_path,
                                      "github.com/o/r2"));
}

void test_has_dep_with_source_mismatch() {
    write_temp_lockfile(({
        ({"mymod", "github.com/o/r1", "v1", "sha1", "h1"}),
    }));
    assert_equal(0, lockfile_has_dep("mymod", lockfile_path,
                                      "github.com/other/repo"));
}

void test_has_dep_case_sensitive() {
    write_temp_lockfile(({
        ({"MyMod", "src", "v1", "sha", "hash"}),
    }));
    assert_equal(0, lockfile_has_dep("mymod", lockfile_path));
    assert_equal(0, lockfile_has_dep("MYMOD", lockfile_path));
    assert_equal(1, lockfile_has_dep("MyMod", lockfile_path));
}

void test_add_entry_empty_source_dies() {
    int code = run_subprocess(
        "import Lockfile; "
        "lockfile_add_entry(({}), \"name\", \"\", \"v1\", \"sha\", \"hash\");"
    );
    assert_true(code != 0, "empty source should have died");
}

void test_merge_entry_empty_name_dies() {
    int code = run_subprocess(
        "import Lockfile; "
        "merge_lock_entries(({ ({\"\", \"s\", \"v1\", \"sha\", \"hash\"}) }), ({}));"
    );
    assert_true(code != 0, "merge with empty name should have died");
}

void test_read_lockfile_no_version_header_dies() {
    string tmppath = combine_path(tmpdir, "no-version.lock");
    Stdio.write_file(tmppath, "foo\tsrc\tv1\tsha\thash\n");
    int code = run_subprocess(
        "import Lockfile; "
        "read_lockfile(\"" + tmppath + "\");"
    );
    assert_true(code != 0, "lockfile without version header should have died");
}
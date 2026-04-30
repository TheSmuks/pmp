//! Adversarial tests for Pmp.Lockfile — read/write edge cases.

import PUnit;
import Lockfile;
inherit PUnit.TestCase;

protected string tmpdir;
protected string lockfile_path;

// Base directory for module resolution in subprocesses
protected string base_dir;

void setup() {
    base_dir = getcwd();
    tmpdir = combine_path(base_dir, ".tmp-test-lockfile-io-" + getpid());
    Stdio.mkdirhier(tmpdir);
    lockfile_path = combine_path(tmpdir, "pike.lock");
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir))
        Process.run(({"rm", "-rf", tmpdir}));
}

//! Run a pike snippet in a subprocess with the same module paths.
//! Returns the exit code.
int run_subprocess(string code) {
    mapping result = Process.run(({
        "pike", "-M", combine_path(base_dir, "modules"),
        "-M", combine_path(base_dir, "bin"),
        "-M", combine_path(base_dir, "bin/core"),
        "-M", combine_path(base_dir, "bin/transport"),
        "-M", combine_path(base_dir, "bin/store"),
        "-M", combine_path(base_dir, "bin/project"),
        "-M", combine_path(base_dir, "bin/commands"),
        "-e", code
    }));
    return result->exitcode;
}

// ── write_lockfile / read_lockfile roundtrip ─────────────────────────

void test_write_read_roundtrip() {
    array(array(string)) entries = ({
        ({"alpha", "github.com/o/a", "v1.0", "sha_a", "hash_a"}),
        ({"beta", "github.com/o/b", "v2.0", "sha_b", "hash_b"}),
    });
    write_lockfile(lockfile_path, entries);
    array(array(string)) read_back = read_lockfile(lockfile_path);
    assert_equal(2, sizeof(read_back));
    assert_equal("alpha", read_back[0][0]);
    assert_equal("github.com/o/a", read_back[0][1]);
    assert_equal("v1.0", read_back[0][2]);
    assert_equal("sha_a", read_back[0][3]);
    assert_equal("hash_a", read_back[0][4]);
    assert_equal("beta", read_back[1][0]);
}

void test_write_empty_entries() {
    write_lockfile(lockfile_path, ({}));
    array(array(string)) read_back = read_lockfile(lockfile_path);
    assert_equal(0, sizeof(read_back));
}

// ── write_lockfile validation (die on bad input) ────────────────────
// die() calls exit() which is uncatchable, so we test in subprocesses.

void test_write_tab_in_field_dies() {
    int code = run_subprocess(
        "import Lockfile; "
        "write_lockfile(\"" + lockfile_path + "\", "
        "({ ({ \"bad\\tmod\", \"src\", \"v1\", \"sha\", \"hash\" }) }));"
    );
    assert_true(code != 0, "tab in field should have died");
}

void test_write_newline_in_field_dies() {
    int code = run_subprocess(
        "import Lockfile; "
        "write_lockfile(\"" + lockfile_path + "\", "
        "({ ({ \"bad\\nmod\", \"src\", \"v1\", \"sha\", \"hash\" }) }));"
    );
    assert_true(code != 0, "newline in field should have died");
}

void test_write_fewer_than_5_fields_dies() {
    int code = run_subprocess(
        "import Lockfile; "
        "write_lockfile(\"" + lockfile_path + "\", "
        "({ ({ \"a\", \"b\", \"c\" }) }));"
    );
    assert_true(code != 0, "entry with <5 fields should have died");
}

// ── read_lockfile edge cases ────────────────────────────────────────

void test_read_windows_line_endings() {
    string content = "# pmp lockfile v1 — DO NOT EDIT\r\n"
        "# name\tsource\ttag\tcommit_sha\tcontent_sha256\r\n"
        "mod1\tgithub.com/o/r\tv1\tsha1\thash1\r\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    assert_equal(1, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
    assert_equal("github.com/o/r", entries[0][1]);
}

void test_read_mixed_line_endings() {
    string content = "# pmp lockfile v1 — DO NOT EDIT\n"
        "# name\tsource\ttag\tcommit_sha\tcontent_sha256\n"
        "mod1\tsrc1\tv1\tsha1\thash1\r\n"
        "mod2\tsrc2\tv2\tsha2\thash2\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    assert_equal(2, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
    assert_equal("mod2", entries[1][0]);
}

void test_read_truncated_entry() {
    string content = "# pmp lockfile v1 — DO NOT EDIT\n"
        "# name\tsource\ttag\tcommit_sha\tcontent_sha256\n"
        "mod1\tsrc1\tv1\n"
        "mod2\tsrc2\tv2\tsha2\thash2\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    // Only the valid 5-field entry should be returned
    assert_equal(1, sizeof(entries));
    assert_equal("mod2", entries[0][0]);
}

void test_read_duplicate_entries() {
    string content = "# pmp lockfile v1 — DO NOT EDIT\n"
        "# name\tsource\ttag\tcommit_sha\tcontent_sha256\n"
        "dup\tsrc\tv1\tsha1\thash1\n"
        "dup\tsrc\tv2\tsha2\thash2\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    // read_lockfile does not deduplicate — both entries returned
    assert_equal(2, sizeof(entries));
    assert_equal("dup", entries[0][0]);
    assert_equal("dup", entries[1][0]);
    assert_equal("sha1", entries[0][3]);
    assert_equal("sha2", entries[1][3]);
}

// ── lockfile_has_dep (in-memory, no disk) ───────────────────

void test_has_dep_entries_empty() {
    assert_equal(0, lockfile_has_dep("anything", 0, 0, ({})));
}

void test_has_dep_entries_match() {
    array(array(string)) entries = ({
        ({"foo", "github.com/o/r", "v1", "sha", "hash"}),
    });
    assert_equal(1, lockfile_has_dep("foo", 0, 0, entries));
}

void test_has_dep_entries_source_mismatch() {
    array(array(string)) entries = ({
        ({"foo", "github.com/o/r1", "v1", "sha", "hash"}),
    });
    assert_equal(0, lockfile_has_dep("foo", 0, "github.com/o/r2", entries));
}

// ── Unversioned lockfile handling ──────────────────────────────────

void test_read_lockfile_no_version_header() {
    // Lockfile with data lines but no version header should still return
    // entries (with a warning to stderr). This tests backward compat.
    string content = "# name\tsource\ttag\tcommit_sha\tcontent_sha256\n"
        "mod1\tsrc1\tv1\tsha1\thash1\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    assert_equal(1, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
}

void test_read_lockfile_version_header_present() {
    string content = "# pmp lockfile v1 — DO NOT EDIT\n"
        "# name\tsource\ttag\tcommit_sha\tcontent_sha256\n"
        "mod1\tsrc1\tv1\tsha1\thash1\n";
    Stdio.write_file(lockfile_path, content);
    array(array(string)) entries = read_lockfile(lockfile_path);
    assert_equal(1, sizeof(entries));
    assert_equal("mod1", entries[0][0]);
}
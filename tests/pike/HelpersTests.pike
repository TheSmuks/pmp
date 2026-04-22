//! Tests for Pmp.Helpers — compute_sha256, json_field, display_name.

import PUnit;
import Pmp.Helpers;
inherit PUnit.TestCase;

// ── compute_sha256 ───────────────────────────────────────────────────

protected string tmpdir;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-helpers-" + getpid());
    Stdio.mkdirhier(tmpdir);
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir))
        Process.run(({"rm", "-rf", tmpdir}));
}

void test_sha256_known_content() {
    string path = combine_path(tmpdir, "test.txt");
    Stdio.write_file(path, "hello\n");
    // SHA-256 of "hello\n"
    string expected = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";
    assert_equal(expected, compute_sha256(path));
}

void test_sha256_empty_file() {
    string path = combine_path(tmpdir, "empty.txt");
    Stdio.write_file(path, "");
    // SHA-256 of empty string
    string expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    assert_equal(expected, compute_sha256(path));
}

void test_sha256_missing_file() {
    assert_equal("unknown", compute_sha256("/nonexistent/file"));
}

// ── json_field ───────────────────────────────────────────────────────

void test_json_field_reads_value() {
    string path = combine_path(tmpdir, "test.json");
    Stdio.write_file(path, Standards.JSON.encode((["name": "pmp", "version": "1.0"])));
    assert_equal("pmp", json_field("name", path));
    assert_equal("1.0", json_field("version", path));
}

void test_json_field_missing_key() {
    string path = combine_path(tmpdir, "test.json");
    Stdio.write_file(path, Standards.JSON.encode((["name": "pmp"])));
    assert_equal(0, json_field("missing", path));
}

void test_json_field_missing_file() {
    assert_equal(0, json_field("name", "/nonexistent/file.json"));
}

void test_json_field_invalid_json() {
    string path = combine_path(tmpdir, "bad.json");
    Stdio.write_file(path, "not valid json {{{");
    assert_equal(0, json_field("name", path));
}

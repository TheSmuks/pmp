//! Adversarial tests for Pmp.Store — edge cases and boundary conditions.

import PUnit;
import Pmp;
inherit PUnit.TestCase;

// ── store_entry_name ─────────────────────────────────────────────────

void test_store_entry_name_basic() {
    string result = store_entry_name("github.com/owner/repo", "v1.0.0",
                                     "abcdef1234567890");
    // Slug derived from src, then tag, then sha prefix
    assert_equal(1, has_value(result, "v1.0.0"));
    assert_equal(1, has_value(result, "abcdef12345678"));  // first 16 chars
    assert_equal(1, has_value(result, "github.com"));
    assert_equal(1, has_value(result, "owner"));
    assert_equal(1, has_value(result, "repo"));
}

void test_store_entry_name_double_slash() {
    string result = store_entry_name("github.com//owner///repo", "v1", "abc");
    // Collapsed dashes — no "--" in output
    assert_equal(0, has_value(result, "--"));
}

void test_store_entry_name_short_sha() {
    string result = store_entry_name("github.com/o/r", "v1", "ab");
    assert_equal(1, has_suffix(result, "-v1-ab"));
}

void test_store_entry_name_long_sha() {
    string sha64 = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";
    string result = store_entry_name("github.com/o/r", "v2", sha64);
    // Only first 16 chars of SHA are used
    string sha16 = sha64[..15];  // "abcdef1234567890"
    assert_equal(1, has_value(result, sha16));
    // The full 64-char SHA must NOT appear (only prefix)
    assert_equal(0, has_value(result, sha64));
}

void test_store_entry_name_leading_trailing_dash() {
    // Path with leading slashes produces leading dashes before trimming
    string result = store_entry_name("/github.com/owner/repo/", "v1", "abc1234567890123");
    assert_equal(0, has_prefix(result, "-"));
    assert_equal(0, has_suffix(result, "-"));
    // And no double dashes
    assert_equal(0, has_value(result, "--"));
}


// die() calls exit() which is uncatchable — test in subprocess.
protected int run_subprocess(string code) {
    mapping result = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-e", code
    }));
    return result->exitcode;
}

// ── compute_dir_hash ─────────────────────────────────────────────────

protected string tmpdir;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-store-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir))
        Stdio.recursive_rm(tmpdir);
}

void test_compute_dir_hash_empty() {
    string empty_dir = combine_path(tmpdir, "empty");
    Stdio.mkdirhier(empty_dir);
    string hash = compute_dir_hash(empty_dir);
    // Empty dir: no files collected, so buffer is empty string,
    // SHA256("") is a fixed 64-char hex string
    assert_equal(64, sizeof(hash));
    // Verify it's all lowercase hex chars
    // Verify it's all hex
    foreach (hash / ""; ; string c)
        if (sizeof(c) > 0)
            assert_equal(1, has_value("0123456789abcdef", c));
}

void test_compute_dir_hash_deterministic() {
    string dir1 = combine_path(tmpdir, "det1");
    string dir2 = combine_path(tmpdir, "det2");
    Stdio.mkdirhier(dir1);
    Stdio.mkdirhier(dir2);
    Stdio.write_file(combine_path(dir1, "file.txt"), "hello world");
    Stdio.write_file(combine_path(dir2, "file.txt"), "hello world");
    assert_equal(compute_dir_hash(dir1), compute_dir_hash(dir2));
}

void test_compute_dir_hash_nested() {
    string dir = combine_path(tmpdir, "nested");
    Stdio.mkdirhier(combine_path(dir, "sub", "deep"));
    Stdio.write_file(combine_path(dir, "top.txt"), "top");
    Stdio.write_file(combine_path(dir, "sub", "mid.txt"), "mid");
    Stdio.write_file(combine_path(dir, "sub", "deep", "bottom.txt"), "bottom");
    string hash = compute_dir_hash(dir);
    assert_equal(64, sizeof(hash));
    // Different content must produce different hash than a flat dir
    string flat_dir = combine_path(tmpdir, "flat");
    Stdio.mkdirhier(flat_dir);
    Stdio.write_file(combine_path(flat_dir, "top.txt"), "top");
    assert_equal(0, equal(hash, compute_dir_hash(flat_dir)));
}

// ── resolve_module_path ──────────────────────────────────────────────

void test_resolve_module_path_pmod_dir() {
    // Create entry_dir with name.pmod/ directory
    string entry = combine_path(tmpdir, "entry-pmoddir");
    Stdio.mkdirhier(combine_path(entry, "MyMod.pmod"));
    Stdio.write_file(combine_path(entry, "MyMod.pmod", "module.pmod"), "");
    mapping m = resolve_module_path("MyMod", entry);
    assert_equal(1, has_value(m["link_name"], ".pmod"));
    assert_equal("MyMod.pmod", m["link_name"]);
}

void test_resolve_module_path_module_pmod() {
    // Create entry_dir with name/module.pmod (subdirectory module)
    string entry = combine_path(tmpdir, "entry-modpmod");
    Stdio.mkdirhier(combine_path(entry, "MyMod"));
    Stdio.write_file(combine_path(entry, "MyMod", "module.pmod"), "// module");
    mapping m = resolve_module_path("MyMod", entry);
    assert_equal(1, has_value(m["link_name"], ".pmod"));
    assert_equal("MyMod.pmod", m["link_name"]);
}


// ── store_entry_name: empty SHA (die in subprocess) ──────────────────

void test_store_entry_name_empty_sha() {
    // die() calls exit() which is uncatchable, so test in subprocess
    int code = run_subprocess(
        "import Pmp.Store; "
        "store_entry_name(\"github.com/owner/repo\", \"v1.0.0\", \"\");"
    );
    assert_true(code != 0, "empty SHA should have died");
}

// ── read_stored_hash ────────────────────────────────────────────────

void test_read_stored_hash_missing_meta() {
    // Dir with no .pmp-meta file returns 0
    string dir = combine_path(tmpdir, "no-meta");
    Stdio.mkdirhier(dir);
    string result = read_stored_hash(dir);
    assert_equal(0, result);
}

void test_read_stored_hash_corrupt_meta() {
    // Dir with .pmp-meta missing content_sha256 line returns 0
    string dir = combine_path(tmpdir, "corrupt-meta");
    Stdio.mkdirhier(dir);
    Stdio.write_file(combine_path(dir, ".pmp-meta"),
        "source\ttest\ntag\tv1\n");  // Missing content_sha256
    string result = read_stored_hash(dir);
    assert_equal(0, result);
}

void test_read_stored_hash_full_sha256() {
    // Verify the off-by-one fix: the full SHA is returned, not truncated
    string dir = combine_path(tmpdir, "full-sha");
    Stdio.mkdirhier(dir);
    string full_sha = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";
    Stdio.write_file(combine_path(dir, ".pmp-meta"),
        "source\ttest\ntag\tv1\ncommit_sha\tsha\ncontent_sha256\t" + full_sha + "\n");
    string result = read_stored_hash(dir);
    assert_equal(full_sha, result);
}

void test_read_stored_hash_empty_meta() {
    // Empty .pmp-meta file returns 0
    string dir = combine_path(tmpdir, "empty-meta");
    Stdio.mkdirhier(dir);
    Stdio.write_file(combine_path(dir, ".pmp-meta"), "");
    string result = read_stored_hash(dir);
    assert_equal(0, result);
}
//! Adversarial tests for Pmp.Verify — edge cases for project and store verification.

import PUnit;
import Pmp.Verify; import Pmp.Store;
inherit PUnit.TestCase;

protected string tmpdir;
protected string old_cwd;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-verify-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
    old_cwd = getcwd();
}

void teardown() {
    if (old_cwd) cd(old_cwd);
    if (tmpdir && Stdio.exist(tmpdir))
        Stdio.recursive_rm(tmpdir);
}

// Build a standard ctx mapping for cmd_verify / cmd_doctor.
protected mapping make_ctx(string project_dir) {
    string store_dir = combine_path(tmpdir, "store");
    Stdio.mkdirhier(store_dir);
    return ([
        "pike_bin": Process.locate_binary((getenv("PATH") || "/usr/bin:/bin") / ":", "pike") || "pike",
        "global_dir": combine_path(tmpdir, "global-modules"),
        "local_dir": combine_path(project_dir, "modules"),
        "store_dir": store_dir,
        "pike_json": combine_path(project_dir, "pike.json"),
        "lockfile_path": combine_path(project_dir, "pike.lock"),
    ]);
}

// Create a minimal project directory with pike.json and modules/.
protected string make_project(string name) {
    string d = combine_path(tmpdir, name);
    Stdio.mkdirhier(combine_path(d, "modules"));
    Stdio.write_file(combine_path(d, "pike.json"),
        "{\"name\":\"" + name + "\",\"dependencies\":{}}");
    return d;
}

// Write a valid lockfile with the given entries.
// Each entry: ({ name, source, tag, sha, hash })
protected void write_lockfile(string path, array(array(string)) entries) {
    string buf = "# pmp lockfile v1 \xe2\x80\x94 DO NOT EDIT\n";
    foreach (entries; ; array(string) e)
        buf += e * "\t" + "\n";
    Stdio.write_file(path, buf);
}

// Write a valid .pmp-meta into a store entry dir.
protected void write_meta(string entry_dir, string source, string tag,
                          void|string sha, void|string content_sha256) {
    Stdio.mkdirhier(entry_dir);
    string s = "source\t" + source + "\n"
             + "tag\t" + tag + "\n";
    if (sha) s += "commit_sha\t" + sha + "\n";
    if (content_sha256) s += "content_sha256\t" + content_sha256 + "\n";
    Stdio.write_file(combine_path(entry_dir, ".pmp-meta"), s);
}

// ── cmd_verify: empty project ──────────────────────────────────────────

void test_verify_empty_project() {
    string proj = make_project("empty-proj");
    mapping ctx = make_ctx(proj);

    int ok = cmd_verify(ctx);
    assert_equal(1, ok, "empty project should pass verification");
}

// ── cmd_verify: broken symlinks ────────────────────────────────────────

void test_verify_broken_symlink() {
    string proj = make_project("broken-symlink");
    mapping ctx = make_ctx(proj);

    // Create a symlink that points to a non-existent target
    string link = combine_path(proj, "modules", "Broken");
    // Use absolute path to guarantee it's non-existent
    string ghost = combine_path(tmpdir, "store", "does-not-exist-abc");
    System.symlink(ghost, link);

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "broken symlink should fail verification");
}

// ── cmd_verify: valid symlinks into store ──────────────────────────────

void test_verify_valid_symlink_to_store() {
    string proj = make_project("valid-symlink");
    mapping ctx = make_ctx(proj);

    // Create a real store entry with valid meta and matching hash
    string entry_dir = combine_path(ctx["store_dir"], "test-pkg-v1-abcdef1234567890");
    Stdio.mkdirhier(combine_path(entry_dir, "TestPkg.pmod"));
    Stdio.write_file(combine_path(entry_dir, "TestPkg.pmod", "module.pmod"), "// ok");
    string hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, "github.com/o/r", "v1", "abcdef1234567890", hash);

    // Symlink module → store entry
    System.symlink(entry_dir, combine_path(proj, "modules", "TestPkg"));

    int ok = cmd_verify(ctx);
    assert_equal(1, ok, "valid store symlink should pass verification");
}

// ── cmd_verify: lockfile entry not installed ───────────────────────────

void test_verify_lockfile_entry_not_installed() {
    string proj = make_project("lockfile-missing");
    mapping ctx = make_ctx(proj);

    write_lockfile(ctx["lockfile_path"], ({
        ({"MyMod", "github.com/o/r", "v1", "abc123", "deadbeef"}),
    }));

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "lockfile entry with no symlink should fail");
}

// ── cmd_verify: installed module not in lockfile ───────────────────────

void test_verify_module_not_in_lockfile() {
    string proj = make_project("module-orphan");
    mapping ctx = make_ctx(proj);

    // Create a symlink to a real store entry
    string entry_dir = combine_path(ctx["store_dir"], "pkg-v1-abc123def4567890");
    Stdio.mkdirhier(combine_path(entry_dir, "Orphan.pmod"));
    Stdio.write_file(combine_path(entry_dir, "Orphan.pmod", "module.pmod"), "");
    string hash = compute_dir_hash(entry_dir);
    write_meta(entry_dir, "github.com/o/r", "v1", "abc123def4567890", hash);

    System.symlink(entry_dir, combine_path(proj, "modules", "Orphan"));

    // Lockfile does not mention Orphan
    write_lockfile(ctx["lockfile_path"], ({
        ({"OtherMod", "github.com/o/r2", "v2", "zzz", "aaa"}),
    }));

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "module not in lockfile should fail");
}

// ── cmd_verify: store entry missing .pmp-meta ──────────────────────────

void test_verify_store_missing_meta() {
    string proj = make_project("store-no-meta");
    mapping ctx = make_ctx(proj);

    // Store entry with no .pmp-meta
    string entry_dir = combine_path(ctx["store_dir"], "broken-entry-v1");
    Stdio.mkdirhier(entry_dir);

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "store entry without meta should fail");
}

// ── cmd_verify: store entry with hash mismatch ─────────────────────────

void test_verify_store_hash_mismatch() {
    string proj = make_project("hash-mismatch");
    mapping ctx = make_ctx(proj);

    string entry_dir = combine_path(ctx["store_dir"], "pkg-v1-hashmismatch01");
    Stdio.mkdirhier(combine_path(entry_dir, "Some.pmod"));
    Stdio.write_file(combine_path(entry_dir, "Some.pmod", "module.pmod"), "content");
    write_meta(entry_dir, "github.com/o/r", "v1", "abcd1234", "00wrong_hash_value_00000000000000000000000000000000000000");

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "hash mismatch should fail");
}

// ── cmd_verify: store entry with missing content_sha256 in meta ────────

void test_verify_store_missing_content_sha256() {
    string proj = make_project("no-sha256");
    mapping ctx = make_ctx(proj);

    string entry_dir = combine_path(ctx["store_dir"], "pkg-v1-nosha256");
    Stdio.mkdirhier(entry_dir);
    Stdio.write_file(combine_path(entry_dir, "file.pike"), "// x");
    // Meta exists but has no content_sha256 line
    write_meta(entry_dir, "github.com/o/r", "v1", "abc123", 0);

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "missing content_sha256 should fail");
}

// ── cmd_verify: no modules directory at all ────────────────────────────

void test_verify_no_modules_dir() {
    string proj = make_project("no-modules-dir");
    // Remove the modules/ directory that make_project created
    Stdio.recursive_rm(combine_path(proj, "modules"));

    mapping ctx = make_ctx(proj);
    // local_dir points to non-existent modules dir — should pass (nothing to check)
    int ok = cmd_verify(ctx);
    assert_equal(1, ok, "missing modules dir should pass (nothing to verify)");
}

// ── cmd_verify: symlink target outside store and project ───────────────

void test_verify_symlink_outside_store() {
    // Use /tmp directly to avoid being inside a project tree
    // (tmpdir is under the repo root, which has pike.json, so
    // find_project_root() would consider symlinks valid local deps)
    string safe_tmp = combine_path("/tmp", "pmp-verify-outside-" + getpid());
    Stdio.mkdirhier(combine_path(safe_tmp, "modules"));
    Stdio.write_file(combine_path(safe_tmp, "pike.json"),
        "{\"name\":\"outside-test\",\"dependencies\":{}}");

    // outside-dir is outside both store and project tree
    string outside = combine_path("/tmp", "pmp-verify-roguetarget-" + getpid());
    Stdio.mkdirhier(outside);
    Stdio.write_file(combine_path(outside, "module.pmod"), "// ok");

    string store_dir = combine_path(safe_tmp, "store");
    Stdio.mkdirhier(store_dir);
    mapping ctx = ([
        "pike_bin": "pike",
        "global_dir": combine_path(safe_tmp, "global-modules"),
        "local_dir": combine_path(safe_tmp, "modules"),
        "store_dir": store_dir,
        "pike_json": combine_path(safe_tmp, "pike.json"),
        "lockfile_path": combine_path(safe_tmp, "pike.lock"),
    ]);

    // cd into the project so find_project_root finds pike.json there
    string saved_cwd = getcwd();
    cd(safe_tmp);

    System.symlink(outside, combine_path(safe_tmp, "modules", "Rogue"));

    int ok = cmd_verify(ctx);
    assert_equal(0, ok, "symlink outside store and project should fail");

    cd(saved_cwd);
    catch { Stdio.recursive_rm(safe_tmp); };
    catch { Stdio.recursive_rm(outside); };
}

// ── cmd_doctor: no pike.json in any parent ─────────────────────────────

void test_doctor_outside_project() {
    // Use tmpdir directly — no pike.json anywhere in its ancestors
    cd(tmpdir);
    mapping ctx = make_ctx(tmpdir);

    // cmd_doctor does not require a project; it should still return ok for
    // the environment checks (pike, git, store). The project section reports
    // "no pike.json found" but that does not set ok=0.
    int ok = cmd_doctor(ctx);
    // Result depends on whether pike binary exists and git is available;
    // we at least verify it returns an int and does not crash.
    assert_true(intp(ok), "cmd_doctor should return an integer");
}

// ── cmd_doctor: project with pike.json ─────────────────────────────────

void test_doctor_inside_project() {
    string proj = make_project("doctor-proj");
    cd(proj);
    mapping ctx = make_ctx(proj);

    int ok = cmd_doctor(ctx);
    assert_true(intp(ok), "cmd_doctor should return an integer");
}

// ── cmd_verify: lockfile with empty module name lines ──────────────────

void test_verify_lockfile_empty_name_skipped() {
    string proj = make_project("lf-empty-name");
    mapping ctx = make_ctx(proj);

    // Lockfile with an entry whose name is empty — should be skipped, not crash
    write_lockfile(ctx["lockfile_path"], ({
        ({"", "github.com/o/r", "v1", "abc", "deadbeef"}),
    }));

    int ok = cmd_verify(ctx);
    // Empty name entries are skipped; no modules installed, no broken symlinks
    assert_equal(1, ok, "empty-name lockfile entries should be skipped");
}

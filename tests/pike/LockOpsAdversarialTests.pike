//! Adversarial tests for Pmp.LockOps — edge cases for lock, rollback, and changelog.

import PUnit;
import Pmp.LockOps; import Pmp.Lockfile; import Pmp.Helpers; import Pmp.Store;
inherit PUnit.TestCase;

protected string tmpdir;
protected string old_cwd;
protected string pike_bin;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-lockops-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
    old_cwd = getcwd();
    pike_bin = Process.locate_binary(
        (getenv("PATH") || "/usr/bin:/bin") / ":", "pike") || "pike";
}

void teardown() {
    if (old_cwd) cd(old_cwd);
    if (tmpdir && Stdio.exist(tmpdir))
        Stdio.recursive_rm(tmpdir);
}

protected mapping make_ctx(string project_dir) {
    string store_dir = combine_path(tmpdir, "store");
    Stdio.mkdirhier(store_dir);
    return ([
        "pike_json": combine_path(project_dir, "pike.json"),
        "lockfile_path": combine_path(project_dir, "pike.lock"),
        "local_dir": combine_path(project_dir, "modules"),
        "store_dir": store_dir,
    ]);
}

protected string make_project(string name, void|mapping deps) {
    string d = combine_path(tmpdir, name);
    Stdio.mkdirhier(combine_path(d, "modules"));
    if (!deps) deps = ([]);
    string json = Standards.JSON.encode((["name": name, "dependencies": deps]));
    Stdio.write_file(combine_path(d, "pike.json"), json);
    return d;
}

protected void write_lockfile(string path, array(array(string)) entries) {
    string buf = "# pmp lockfile v1 \xe2\x80\x94 DO NOT EDIT\n";
    foreach (entries; ; array(string) e)
        buf += e * "\t" + "\n";
    Stdio.write_file(path, buf);
}

// Run a Pike expression in a subprocess. Returns ({exit_code, stdout, stderr}).
protected array run_pike(string expr) {
    object proc = Process.Process(
        ({pike_bin, "-M", combine_path(old_cwd, "bin"), "-e", expr}),
        (["stdout": Stdio.PIPE, "stderr": Stdio.PIPE]));
    proc->wait();
    return ({proc->status(), proc->stdout()->read(), proc->stderr()->read()});
}

// Build a Pike expression string that calls cmd_X with a ctx mapping.
protected string ctx_expr(string func, mapping ctx) {
    // Build mapping literal from ctx
    string m = "";
    foreach(indices(ctx); int i; string k) {
        if (i > 0) m += ",";
        m += "\"" + k + "\":\"" + ctx[k] + "\"";
    }
    return "import Pmp; Pmp.LockOps." + func + "(([" + m + "]))";
}

// ── cmd_changelog: non-die paths (direct call) ────────────────────────

void test_changelog_no_args() {
    // cmd_changelog requires args — calls die()
    array result = run_pike(
        "import Pmp; Pmp.LockOps.cmd_changelog(({}), ([]));");
    assert_not_equal(0, result[0],
        "changelog with no args should exit non-zero");
}

void test_changelog_local_dep_no_remote() {
    string proj = make_project("changelog-local");
    mapping ctx = make_ctx(proj);

    write_lockfile(ctx["lockfile_path"], ({
        ({"MyLib", "./libs/my-lib", "-", "sha1", "hash1"}),
    }));
    write_lockfile(ctx["lockfile_path"] + ".prev", ({
        ({"MyLib", "./libs/my-lib", "-", "sha0", "hash0"}),
    }));

    mixed err = catch { cmd_changelog(({"MyLib"}), ctx); };
    assert_false(!!err, "changelog for local dep should not die");
}

void test_changelog_same_sha_no_changes() {
    string proj = make_project("changelog-same");
    mapping ctx = make_ctx(proj);

    write_lockfile(ctx["lockfile_path"], ({
        ({"MyPkg", "github.com/u/pkg", "v1.0.0", "abc123", "hash1"}),
    }));
    write_lockfile(ctx["lockfile_path"] + ".prev", ({
        ({"MyPkg", "github.com/u/pkg", "v1.0.0", "abc123", "hash0"}),
    }));

    mixed err = catch { cmd_changelog(({"MyPkg"}), ctx); };
    assert_false(!!err, "changelog with same SHA should not die");
}

void test_changelog_missing_module() {
    string proj = make_project("changelog-missing");
    mapping ctx = make_ctx(proj);

    write_lockfile(ctx["lockfile_path"], ({
        ({"OtherMod", "github.com/u/r", "v1.0.0", "sha1", "hash1"}),
    }));
    write_lockfile(ctx["lockfile_path"] + ".prev", ({
        ({"OtherMod", "github.com/u/r", "v0.9.0", "sha0", "hash0"}),
    }));

    // die() paths must use subprocess
    array result = run_pike(sprintf(
        "import Pmp; Pmp.Lockfile; Pmp.LockOps.cmd_changelog(({\"MissingMod\"}), "
        + "([\"lockfile_path\":\"%s\"]));",
        ctx["lockfile_path"]));
    assert_not_equal(0, result[0],
        "changelog with missing module should exit non-zero");
}

void test_changelog_prev_missing_module() {
    string proj = make_project("changelog-no-prev-mod");
    mapping ctx = make_ctx(proj);

    write_lockfile(ctx["lockfile_path"], ({
        ({"MyPkg", "github.com/u/pkg", "v2.0.0", "sha2", "hash2"}),
    }));
    write_lockfile(ctx["lockfile_path"] + ".prev", ({
        ({"OtherPkg", "github.com/u/other", "v1.0.0", "sha1", "hash1"}),
    }));

    array result = run_pike(sprintf(
        "import Pmp; Pmp.Lockfile; Pmp.LockOps.cmd_changelog(({\"MyPkg\"}), "
        + "([\"lockfile_path\":\"%s\"]));",
        ctx["lockfile_path"]));
    assert_not_equal(0, result[0],
        "changelog with module missing from prev should exit non-zero");
}

// ── cmd_rollback: die paths (subprocess) ──────────────────────────────

void test_rollback_without_prev() {
    string proj = make_project("rollback-no-prev");
    mapping ctx = make_ctx(proj);

    array result = run_pike(sprintf(
        "import Pmp; Pmp.LockOps.cmd_rollback((["
        + "\"pike_json\":\"%s\","
        + "\"lockfile_path\":\"%s\","
        + "\"local_dir\":\"%s\","
        + "\"store_dir\":\"%s\""
        + "]));",
        ctx["pike_json"], ctx["lockfile_path"],
        ctx["local_dir"], ctx["store_dir"]));
    assert_not_equal(0, result[0],
        "rollback without .prev should exit non-zero");
}

void test_rollback_with_empty_prev() {
    string proj = make_project("rollback-empty-prev");
    mapping ctx = make_ctx(proj);
    write_lockfile(ctx["lockfile_path"] + ".prev", ({}));

    array result = run_pike(sprintf(
        "import Pmp; Pmp.LockOps.cmd_rollback((["
        + "\"pike_json\":\"%s\","
        + "\"lockfile_path\":\"%s\","
        + "\"local_dir\":\"%s\","
        + "\"store_dir\":\"%s\""
        + "]));",
        ctx["pike_json"], ctx["lockfile_path"],
        ctx["local_dir"], ctx["store_dir"]));
    assert_not_equal(0, result[0],
        "rollback with empty .prev should exit non-zero");
}

void test_rollback_restores_local_dep() {
    string proj = make_project("rollback-restore");
    mapping ctx = make_ctx(proj);

    // Create a local dep
    string lib = combine_path(proj, "libs", "my-lib");
    Stdio.mkdirhier(combine_path(lib, "MyLib.pmod"));
    Stdio.write_file(combine_path(lib, "MyLib.pmod", "module.pmod"), "// lib v1");

    write_lockfile(ctx["lockfile_path"] + ".prev", ({
        ({"MyLib", "./libs/my-lib", "-", "sha123", "hash456"}),
    }));

    array result = run_pike(sprintf(
        "import Pmp; Pmp.LockOps.cmd_rollback((["
        + "\"pike_json\":\"%s\","
        + "\"lockfile_path\":\"%s\","
        + "\"local_dir\":\"%s\","
        + "\"store_dir\":\"%s\""
        + "]));",
        ctx["pike_json"], ctx["lockfile_path"],
        ctx["local_dir"], ctx["store_dir"]));
    assert_equal(0, result[0], "rollback with valid local dep should succeed");
    string link = combine_path(ctx["local_dir"], "MyLib.pmod");
    assert_true(Stdio.exist(link) || is_symlink(link),
        "rollback should create symlink for local dep");
}

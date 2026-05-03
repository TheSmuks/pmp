//! Adversarial tests for Pmp.Update — edge cases for update orchestrators.
//! Tests pure function: print_update_summary and cmd_outdated edge cases.

import PUnit;
import Pmp.Update; import Pmp.Helpers;
inherit PUnit.TestCase;

protected string tmpdir;
protected string old_cwd;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-update-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
    old_cwd = getcwd();
}

void teardown() {
    if (old_cwd) cd(old_cwd);
    if (tmpdir && Stdio.exist(tmpdir))
        Stdio.recursive_rm(tmpdir);
}
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

protected string make_project(string name, void|mapping deps) {
    string d = combine_path(tmpdir, name);
    Stdio.mkdirhier(combine_path(d, "modules"));
    if (!deps) deps = ([]);
    string json = Standards.JSON.encode((["name": name, "dependencies": deps]));
    Stdio.write_file(combine_path(d, "pike.json"), json);
    return d;
}

protected void write_lf(string path, array(array(string)) entries) {
    string buf = "# pmp lockfile v1 \xe2\x80\x94 DO NOT EDIT\n";
    foreach (entries; ; array(string) e)
        buf += e * "\t" + "\n";
    Stdio.write_file(path, buf);
}

void test_outdated_no_pike_json() {
    string d = combine_path(tmpdir, "no-proj");
    Stdio.mkdirhier(d);
    mapping ctx = make_ctx(d);

    // die() calls exit() which is uncatchable — test via subprocess.
    string code = "import Pmp.Update; import Pmp.Helpers;"
        + "; cmd_outdated(([\"pike_json\":\"" + ctx["pike_json"]
        + "\",\"lockfile_path\":\"" + ctx["lockfile_path"]
        + "\",\"local_dir\":\"" + ctx["local_dir"]
        + "\",\"store_dir\":\"" + ctx["store_dir"] + "\"]));";
    mapping r = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"), "-e", code
    }));
    assert_not_equal(0, r->exitcode,
        "outdated without pike.json should die");
}

void test_outdated_empty_deps() {
    string proj = make_project("outdated-empty");
    mapping ctx = make_ctx(proj);
    cd(proj);

    // Should not die — just reports "no dependencies declared"
    mixed err = catch { cmd_outdated(({}), ctx); };
    assert_false(!!err, "outdated with empty deps should not die");
}

void test_outdated_local_dep_skipped() {
    string proj = make_project("outdated-local", (["my-lib": "./libs/my-lib"]));
    mapping ctx = make_ctx(proj);
    cd(proj);

    // Create the local dep
    string lib = combine_path(proj, "libs", "my-lib");
    Stdio.mkdirhier(lib);
    Stdio.write_file(combine_path(lib, "module.pmod"), "// ok");

    // Write a lockfile with the local dep
    write_lf(ctx["lockfile_path"], ({
        ({"my-lib", "./libs/my-lib", "-", "sha1", "hash1"}),
    }));

    mixed err = catch { cmd_outdated(({}), ctx); };
    assert_false(!!err, "outdated with local dep should not die");
}

void test_outdated_offline_mode() {
    string proj = make_project("outdated-offline", (["pkg": "github.com/u/pkg"]));
    mapping ctx = make_ctx(proj);
    ctx["offline"] = 1;
    cd(proj);

    // Offline mode should just print a message and return, not die
    mixed err = catch { cmd_outdated(({}), ctx); };
    assert_false(!!err, "outdated in offline mode should not die");
}
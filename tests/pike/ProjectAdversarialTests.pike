//! Adversarial tests for Pmp.Project — edge cases for project management.

import PUnit;
import Pmp;
inherit PUnit.TestCase;

protected string tmpdir;
protected string old_cwd;

// Base directory for module resolution in subprocesses
protected string base_dir;

void setup() {
    old_cwd = getcwd();
    base_dir = old_cwd;
    tmpdir = combine_path(getcwd(), ".tmp-test-project-" + getpid());
    Stdio.mkdirhier(tmpdir);
}

void teardown() {
    catch { cd(old_cwd); };
    if (tmpdir && Stdio.exist(tmpdir))
        catch { Stdio.recursive_rm(tmpdir); };
}

//! Build a standard context mapping for tests, rooted in tmpdir.
protected mapping make_ctx(void|string project_dir) {
    string d = project_dir || tmpdir;
    return ([
        "pike_bin": "pike",
        "global_dir": combine_path(d, "global_modules"),
        "local_dir": combine_path(d, "modules"),
        "store_dir": combine_path(d, "store"),
        "pike_json": combine_path(d, "pike.json"),
        "lockfile_path": combine_path(d, "pike.lock"),
    ]);
}

//! Run a pike snippet in a subprocess with the same module paths.
//! Returns the full Process.run result mapping.
protected mapping run_subprocess_full(string code) {
    return Process.run(({
        "pike",
        "-M", combine_path(base_dir, "modules"),
        "-M", combine_path(base_dir, "bin"),
        "-M", combine_path(base_dir, "bin/core"),
        "-M", combine_path(base_dir, "bin/transport"),
        "-M", combine_path(base_dir, "bin/store"),
        "-M", combine_path(base_dir, "bin/project"),
        "-M", combine_path(base_dir, "bin/commands"),
        "-e", code
    }));
}

protected int run_subprocess(string code) {
    return run_subprocess_full(code)->exitcode;
}

// ── cmd_init ───────────────────────────────────────────────────────

void test_init_creates_pike_json() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    mixed err = catch { cmd_init(ctx); };
    assert_false(!!err, "init should not throw");
    assert_true(Stdio.exist(ctx["pike_json"]), "pike.json should exist");

    // Verify content structure
    string raw = Stdio.read_file(ctx["pike_json"]);
    assert_not_null(raw, "pike.json should be readable");
    mixed data = Standards.JSON.decode(raw);
    assert_true(mappingp(data), "pike.json should decode to mapping");
    assert_equal("0.1.0", data["version"], "version should be 0.1.0");
    assert_true(mappingp(data["dependencies"]), "dependencies should be a mapping");
    assert_equal(sizeof(data["dependencies"]), 0, "dependencies should start empty");
}

void test_init_rejects_existing_pike_json() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Pre-create pike.json
    Stdio.write_file(ctx["pike_json"], "{}\n");
    assert_true(Stdio.exist(ctx["pike_json"]), "precondition: pike.json exists");

    // cmd_init should die() — test via subprocess
    int code = run_subprocess(
        "import Pmp; "
        + "cd(\"" + tmpdir + "\"); "
        + "cmd_init(([\"pike_json\":\"" + ctx["pike_json"] + "\"]));"
    );
    // die() exits with EXIT_ERROR (1)
    assert_equal(1, code, "init should die when pike.json already exists");
}

void test_init_names_project_after_directory() {
    // Create a subdirectory with a known name
    string named_dir = combine_path(tmpdir, "my-cool-project");
    mkdir(named_dir);
    mapping ctx = make_ctx(named_dir);
    cd(named_dir);

    mixed err = catch { cmd_init(ctx); };
    assert_false(!!err, "init should not throw");

    string raw = Stdio.read_file(ctx["pike_json"]);
    mapping data = Standards.JSON.decode(raw);
    assert_equal("my-cool-project", data["name"],
        "pike.json name should match directory name");
}

void test_init_atomic_write_no_stale_tmp() {
    // After init, no .tmp file should linger
    mapping ctx = make_ctx();
    cd(tmpdir);

    mixed err = catch { cmd_init(ctx); };
    assert_false(!!err, "init should not throw");

    // Check no .tmp files remain
    array(string) entries = get_dir(tmpdir) || ({});
    entries = filter(entries, lambda(string e) { return has_prefix(e, "pike.json.tmp"); });
    assert_equal(0, sizeof(entries), "no temp files should remain after init");
}

// ── cmd_list ───────────────────────────────────────────────────────

void test_list_empty_modules_dir() {
    mapping ctx = make_ctx();
    cd(tmpdir);
    // modules dir does not exist — cmd_list should not crash
    mixed err = catch {
        cmd_list(({}), ctx);
    };
    assert_false(!!err, "list should not throw when modules dir missing");
}

void test_list_json_output_empty() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Capture stdout via subprocess — JSON flag
    string code = "import Pmp; "
        + "cmd_list(({\"--json\"}), ("
        + "  [\"global_dir\":\"" + ctx["global_dir"] + "\","
        + "   \"local_dir\":\"" + ctx["local_dir"] + "\","
        + "   \"store_dir\":\"" + ctx["store_dir"] + "\"]));";

    mapping r = run_subprocess_full(code);
    assert_equal(0, r->exitcode, "list --json should succeed");
    // Should output "[]" since no modules dir exists
    assert_true(has_prefix(String.trim_all_whites(r->stdout), "["),
        "JSON output should start with [");
}

void test_list_with_non_directory_entries() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Create modules dir with a regular file (not a directory)
    mkdir(ctx["local_dir"]);
    Stdio.write_file(combine_path(ctx["local_dir"], "README.txt"), "not a module");

    mixed err = catch {
        cmd_list(({}), ctx);
    };
    assert_false(!!err, "list should skip non-directory entries without error");
}

void test_list_global_flag() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Global dir does not exist — should not crash with -g
    mixed err = catch {
        cmd_list(({"-g"}), ctx);
    };
    assert_false(!!err, "list -g should not throw when global dir missing");
}

// ── cmd_clean ──────────────────────────────────────────────────────

void test_clean_already_clean() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // local_dir does not exist — clean should handle gracefully
    mixed err = catch {
        cmd_clean(ctx);
    };
    assert_false(!!err, "clean should not throw when nothing to clean");
    assert_false(Stdio.exist(ctx["local_dir"]),
        "local_dir should still not exist after clean");
}

void test_clean_removes_modules_dir() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Create modules dir with a plain directory (non-symlink)
    string mod_dir = combine_path(ctx["local_dir"], "TestMod.pmod");
    Stdio.mkdirhier(mod_dir);
    Stdio.write_file(combine_path(mod_dir, "module.pike"), "// test\n");

    assert_true(Stdio.is_dir(ctx["local_dir"]), "precondition: modules dir exists");

    mixed err = catch { cmd_clean(ctx); };
    assert_false(!!err, "clean should not throw");
    // Non-symlink content should be preserved by clean
    assert_true(Stdio.is_dir(ctx["local_dir"]),
        "modules dir should be preserved when it has non-symlink content");
    assert_true(Stdio.is_dir(mod_dir),
        "non-symlink module content should be preserved");
}

void test_clean_counts_symlinks() {
    mapping ctx = make_ctx();
    cd(tmpdir);

    // Create modules dir with a symlink
    mkdir(ctx["local_dir"]);
    string target = combine_path(tmpdir, "some_target");
    mkdir(target);
    System.symlink(target, combine_path(ctx["local_dir"], "linked.pmod"));

    mixed err = catch { cmd_clean(ctx); };
    assert_false(!!err, "clean should handle symlinks");
    assert_false(Stdio.is_dir(ctx["local_dir"]),
        "modules dir removed even when it contains symlinks");
}

// ── cmd_remove ─────────────────────────────────────────────────────

void test_remove_no_args_dies() {
    // cmd_remove with empty args should die("usage: ...")
    int code = run_subprocess(
        "import Pmp; "
        + "cmd_remove(({}), ([]));"
    );
    assert_equal(1, code, "remove with no args should die with EXIT_ERROR");
}

void test_remove_path_traversal_slash() {
    int code = run_subprocess(
        "import Pmp; "
        + "cmd_remove(({\"etc/passwd\"}), ([]));"
    );
    assert_equal(1, code,
        "remove with slash in name should die (path traversal)");
}

void test_remove_path_traversal_dotdot() {
    int code = run_subprocess(
        "import Pmp; "
        + "cmd_remove(({\"..\"}), ([]));"
    );
    assert_equal(1, code,
        "remove with .. should die (path traversal)");
}

void test_remove_path_traversal_null_byte() {
    int code = run_subprocess(
        "import Pmp; "
        + "cmd_remove(({\"foo\\0bar\"}), ([]));"
    );
    assert_equal(1, code,
        "remove with null byte should die (path traversal)");
}

void test_remove_not_found_dies() {
    string d = combine_path(getcwd(), ".tmp-test-rm-" + getpid());
    Stdio.mkdirhier(d);
    cd(d);
    // Create a pike.json so cmd_remove doesn't skip that branch
    mapping data = (["name": "test", "version": "0.1.0", "dependencies": ([])]);
    Stdio.write_file(combine_path(d, "pike.json"),
        Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");

    int code = run_subprocess(
        "import Pmp; "
        + "cd(\"" + d + "\"); "
        + "cmd_remove(({\"nonexistent\"}), (["
        + "  \"pike_json\":\"" + combine_path(d, "pike.json") + "\","
        + "  \"local_dir\":\"" + combine_path(d, "modules") + "\","
        + "  \"lockfile_path\":\"" + combine_path(d, "pike.lock") + "\""
        + "]));"
    );
    // Should die("nothing to remove: nonexistent not found")
    assert_equal(1, code, "remove of nonexistent module should die");

    cd(old_cwd);
    catch { Stdio.recursive_rm(d); };
}

void test_remove_strips_pmod_suffix() {
    // Verify that passing "Foo.pmod" correctly strips .pmod and still finds
    // the dependency by bare name in pike.json
    string d = combine_path(getcwd(), ".tmp-test-rmpmod-" + getpid());
    Stdio.mkdirhier(d);
    cd(d);

    // Create pike.json with a dependency named "TestMod"
    mapping data = ([
        "name": "test",
        "version": "0.1.0",
        "dependencies": (["TestMod": "github.com/o/t"])
    ]);
    Stdio.write_file(combine_path(d, "pike.json"),
        Standards.JSON.encode(data, Standards.JSON.HUMAN_READABLE) + "\n");

    // Create modules dir with symlink
    mkdir(combine_path(d, "modules"));
    string target = combine_path(d, "target");
    mkdir(target);
    System.symlink(target, combine_path(d, "modules", "TestMod.pmod"));

    mapping ctx = ([
        "pike_json": combine_path(d, "pike.json"),
        "local_dir": combine_path(d, "modules"),
        "lockfile_path": combine_path(d, "pike.lock"),
    ]);

    mixed err = catch { cmd_remove(({"TestMod.pmod"}), ctx); };
    assert_false(!!err, "remove should accept .pmod suffix and strip it");

    // Verify dependency was removed from pike.json
    string raw = Stdio.read_file(combine_path(d, "pike.json"));
    mapping updated = Standards.JSON.decode(raw);
    assert_true(zero_type(updated["dependencies"]["TestMod"]),
        "TestMod should be removed from dependencies");

    cd(old_cwd);
    catch { Stdio.recursive_rm(d); };
}

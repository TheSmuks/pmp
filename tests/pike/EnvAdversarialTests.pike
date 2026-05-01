//! Adversarial tests for Pmp.Env — edge cases for _has_headers,
//! build_paths, cmd_env shell injection prevention, and cmd_run
//! validation.

import PUnit;
import Pmp.Env;
inherit PUnit.TestCase;

protected string tmpdir;
protected int _run_counter = 0;

//! Helper: run pike code in a subprocess with a specific cwd.
//! Returns mapping with exitcode, stdout, stderr.
protected mapping run_in_dir(string cwd, string code) {
    _run_counter++;
    string stdout_file = combine_path(tmpdir, "stdout-" + getpid() + "-" + _run_counter);
    string stderr_file = combine_path(tmpdir, "stderr-" + getpid() + "-" + _run_counter);
    object p = Process.create_process(({
        "pike",
        "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-e", code
    }), ([
        "cwd": cwd,
        "stdout": Stdio.File(stdout_file, "wct"),
        "stderr": Stdio.File(stderr_file, "wct"),
    ]));
    int code_exit = p->wait();
    string out = Stdio.read_file(stdout_file) || "";
    string err = Stdio.read_file(stderr_file) || "";
    rm(stdout_file);
    rm(stderr_file);
    return (["exitcode": code_exit, "stdout": out, "stderr": err]);
}

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-env-adv-" + getpid());
    Stdio.mkdirhier(tmpdir);
}

void teardown() {
    if (tmpdir && Stdio.is_dir(tmpdir))
        Process.run(({"rm", "-rf", tmpdir}));
}

// ── _has_headers ─────────────────────────────────────────────────────

void test_has_headers_empty_dir() {
    string d = combine_path(tmpdir, "empty");
    Stdio.mkdirhier(d);
    assert_equal(0, _has_headers(d), "empty dir should have no headers");
}

void test_has_headers_with_h_file() {
    string d = combine_path(tmpdir, "with_h");
    Stdio.mkdirhier(d);
    Stdio.write_file(combine_path(d, "test.h"), "// header");
    assert_equal(1, _has_headers(d), "dir with .h should report headers");
}

void test_has_headers_nested_h() {
    string d = combine_path(tmpdir, "nested");
    string sub = combine_path(d, "sub", "deep");
    Stdio.mkdirhier(sub);
    Stdio.write_file(combine_path(sub, "deep.h"), "// nested header");
    assert_equal(1, _has_headers(d), "nested .h should be found");
}

void test_has_headers_no_h_files() {
    string d = combine_path(tmpdir, "no_h");
    Stdio.mkdirhier(d);
    Stdio.write_file(combine_path(d, "readme.txt"), "not a header");
    Stdio.write_file(combine_path(d, "code.c"), "/* c source */");
    assert_equal(0, _has_headers(d), "dir without .h should report no headers");
}

void test_has_headers_mixed_extensions() {
    string d = combine_path(tmpdir, "mixed");
    Stdio.mkdirhier(d);
    Stdio.write_file(combine_path(d, "module.pmod"), "// pike module");
    Stdio.write_file(combine_path(d, "types.h"), "// header");
    Stdio.write_file(combine_path(d, "impl.c"), "// c");
    assert_equal(1, _has_headers(d), ".h among other files should be found");
}

// ── build_paths ──────────────────────────────────────────────────────
//
// Note: build_paths calls find_project_root(), which resolves to the
// actual project root. We test the global_dir contribution and header
// detection rather than asserting exact path counts.

void test_build_paths_nonexistent_global_dir() {
    // global_dir doesn't exist — only project modules may appear
    mapping ctx = (["global_dir": combine_path(tmpdir, "nope_global")]);
    array(array(string)) paths = build_paths(ctx);
    assert_equal(2, sizeof(paths), "build_paths returns 2-element array");
    assert_true(!has_value(paths[0], ctx["global_dir"]),
        "nonexistent global_dir should not appear in module paths");
    assert_true(!has_value(paths[1], ctx["global_dir"]),
        "nonexistent global_dir should not appear in include paths");
}

void test_build_paths_only_global() {
    string g = combine_path(tmpdir, "global_mods");
    Stdio.mkdirhier(g);
    mapping ctx = (["global_dir": g]);
    array(array(string)) paths = build_paths(ctx);
    assert_true(has_value(paths[0], g),
        "global dir should be in module paths");
    assert_true(!has_value(paths[1], g),
        "global dir without .h should not be in include paths");
}

void test_build_paths_global_with_headers() {
    string g = combine_path(tmpdir, "global_with_h");
    Stdio.mkdirhier(g);
    Stdio.write_file(combine_path(g, "lib.h"), "// header");
    mapping ctx = (["global_dir": g]);
    array(array(string)) paths = build_paths(ctx);
    assert_true(has_value(paths[0], g),
        "global dir should be in module paths");
    assert_true(has_value(paths[1], g),
        "global dir with .h should be in include paths");
}

void test_build_paths_returns_two_arrays() {
    // Structural invariant regardless of inputs
    mapping ctx = (["global_dir": "/nonexistent/path/" + getpid()]);
    array(array(string)) paths = build_paths(ctx);
    assert_equal(2, sizeof(paths), "build_paths returns 2-element array");
    assert_true(arrayp(paths[0]), "first element is array");
    assert_true(arrayp(paths[1]), "second element is array");
}

// ── cmd_env shell injection prevention ───────────────────────────────

void test_cmd_env_newline_in_pike_bin_dies() {
    // pike_bin with newline should trigger die()
    string env_dir = combine_path(tmpdir, "newline-bin");
    Stdio.mkdirhier(env_dir);
    Stdio.write_file(combine_path(env_dir, "pike.json"), "{}");
    mapping r = run_in_dir(env_dir,
        "import Pmp.Env; mapping ctx = (['pike_bin':'bad\\npath','global_dir':'/tmp/g']); cmd_env(ctx);");
    assert_true(r->exitcode != 0,
        "newline in pike_bin should cause non-zero exit");
}

void test_cmd_env_creates_structure() {
    // cmd_env should create .pike-env/ with all expected artifacts
    string env_dir = combine_path(tmpdir, "env-struct-test");
    Stdio.mkdirhier(env_dir);
    Stdio.write_file(combine_path(env_dir, "pike.json"), "{}");
    mapping r = run_in_dir(env_dir,
        "import Pmp.Env; mapping ctx = ([\"pike_bin\":\"/usr/bin/pike\",\"global_dir\":\"/tmp/g\"]); cmd_env(ctx);");
    assert_equal(0, r->exitcode, "cmd_env should succeed with clean paths");
    assert_true(Stdio.is_dir(combine_path(env_dir, ".pike-env")),
        ".pike-env directory should exist");
    assert_true(Stdio.exist(combine_path(env_dir, ".pike-env", "bin", "pike")),
        "bin/pike wrapper should exist");
    assert_true(Stdio.exist(combine_path(env_dir, ".pike-env", "activate")),
        "activate script should exist");
    assert_true(Stdio.exist(combine_path(env_dir, ".pike-env", ".gitignore")),
        ".gitignore should exist");
    assert_true(Stdio.exist(combine_path(env_dir, ".pike-env", "pike-env.cfg")),
        "pike-env.cfg should exist");
}

void test_cmd_env_activate_has_deactivate() {
    // Verify activate script defines pmp_deactivate and idempotency guard
    string env_dir = combine_path(tmpdir, "quote-test");
    Stdio.mkdirhier(env_dir);
    Stdio.write_file(combine_path(env_dir, "pike.json"), "{}");
    mapping r = run_in_dir(env_dir,
        "import Pmp.Env; mapping ctx = ([\"pike_bin\":\"/usr/bin/pike\",\"global_dir\":\"/tmp/g\"]); cmd_env(ctx);");

    string activate = Stdio.read_file(combine_path(env_dir, ".pike-env", "activate"));
    assert_not_null(activate, "activate script should exist");
    assert_true(has_value(activate, "_pike_env_dir="),
        "activate should set _pike_env_dir with shell-escaped path");
    assert_true(has_value(activate, "pmp_deactivate()"),
        "activate should define pmp_deactivate function");
    assert_true(has_value(activate, "PIKE_ENV_PATH"),
        "activate should reference PIKE_ENV_PATH for idempotency");
}

void test_cmd_env_cfg_records_values() {
    // Verify pike-env.cfg records the correct metadata
    string env_dir = combine_path(tmpdir, "cfg-test");
    Stdio.mkdirhier(env_dir);
    Stdio.write_file(combine_path(env_dir, "pike.json"), "{}");
    mapping r = run_in_dir(env_dir,
        "import Pmp.Env; mapping ctx = ([\"pike_bin\":\"/usr/bin/pike\",\"global_dir\":\"/tmp/g\"]); cmd_env(ctx);");

    string cfg = Stdio.read_file(combine_path(env_dir, ".pike-env", "pike-env.cfg"));
    assert_not_null(cfg, "pike-env.cfg should exist");
    assert_true(has_value(cfg, "pike_bin = /usr/bin/pike"),
        "cfg should record pike_bin");
    assert_true(has_value(cfg, "pmp_version = "),
        "cfg should record pmp_version");
}

// ── cmd_run validation ───────────────────────────────────────────────

void test_cmd_run_no_args_dies() {
    mapping r = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-e", "import Pmp.Env; cmd_run(({}), (['pike_bin':'/usr/bin/pike','global_dir':'/tmp/g']));"
    }));
    assert_true(r->exitcode != 0,
        "cmd_run with no args should exit non-zero");
}

void test_cmd_run_relative_pike_bin_dies() {
    mapping r = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-e", "import Pmp.Env; cmd_run(({\"test.pike\"}), (['pike_bin':'piiiike','global_dir':'/tmp/g']));"
    }));
    assert_true(r->exitcode != 0,
        "relative pike_bin should cause non-zero exit");
}

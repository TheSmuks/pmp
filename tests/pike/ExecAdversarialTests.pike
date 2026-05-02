//! Adversarial tests for Pmp.Exec — entry point resolution logic.
//! Tests _find_entry_point by creating temp directory fixtures with
//! various file layouts and verifying the correct script is found.

import PUnit;
import Pmp.Exec;
import Pmp.Helpers;
inherit PUnit.TestCase;

// ── Helper: create a temp fixture directory ─────────────────────────

protected string make_fixture(void|array(string) files_and_content) {
    // Create a temp directory and populate it with files.
    // files_and_content is an even-length array: { "filename", "content", ... }
    // Returns the temp directory path.
    string tmpdir = combine_path(getcwd(), ".test-exec-" + random(100000));
    Stdio.mkdirhier(tmpdir);
    if (arrayp(files_and_content)) {
        for (int i = 0; i < sizeof(files_and_content); i += 2) {
            string path = combine_path(tmpdir, files_and_content[i]);
            Stdio.write_file(path, files_and_content[i + 1]);
        }
    }
    return tmpdir;
}

protected void cleanup_fixture(string dir) {
    if (dir && dir != "" && Stdio.exist(dir)) {
        // Remove test fixture directory
        Process.run(({"rm", "-rf", dir}));
    }
}

// ── pike.json bin field ─────────────────────────────────────────────

void test_bin_field_in_pike_json() {
    string d = make_fixture(({
        "pike.json", "{\"bin\": \"tool.pike\"}",
        "tool.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "tool.pike"),
        "bin field should resolve to tool.pike, got: " + result);
    cleanup_fixture(d);
}

void test_bin_field_nonexistent() {
    // bin field points to missing file — should fall through to heuristics
    string d = make_fixture(({
        "pike.json", "{\"bin\": \"missing.pike\"}"
    }));
    string result = _find_entry_point(d);
    assert_equal("", result,
        "missing bin file should return empty (no fallback matches)");
    cleanup_fixture(d);
}

// ── Heuristic filenames ────────────────────────────────────────────

void test_main_pike_heuristic() {
    string d = make_fixture(({
        "main.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "main.pike"),
        "should find main.pike, got: " + result);
    cleanup_fixture(d);
}

void test_cli_pike_heuristic() {
    string d = make_fixture(({
        "cli.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "cli.pike"),
        "should find cli.pike, got: " + result);
    cleanup_fixture(d);
}

void test_cmd_pike_heuristic() {
    string d = make_fixture(({
        "cmd.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "cmd.pike"),
        "should find cmd.pike, got: " + result);
    cleanup_fixture(d);
}

// ── Priority: main.pike > cli.pike > cmd.pike ──────────────────────

void test_priority_main_over_cli() {
    string d = make_fixture(({
        "main.pike", "int main() { return 0; }",
        "cli.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "main.pike"),
        "main.pike should take priority over cli.pike, got: " + result);
    cleanup_fixture(d);
}

void test_priority_cli_over_cmd() {
    string d = make_fixture(({
        "cli.pike", "int main() { return 0; }",
        "cmd.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "cli.pike"),
        "cli.pike should take priority over cmd.pike, got: " + result);
    cleanup_fixture(d);
}

// ── Single .pike file fallback ──────────────────────────────────────

void test_single_pike_file() {
    string d = make_fixture(({
        "app.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "app.pike"),
        "single .pike file should be found, got: " + result);
    cleanup_fixture(d);
}

// ── Multiple .pike files — ambiguous ───────────────────────────────

void test_multiple_pike_files_ambiguous() {
    string d = make_fixture(({
        "a.pike", "int main() { return 0; }",
        "b.pike", "int main() { return 1; }"
    }));
    string result = _find_entry_point(d);
    assert_equal("", result,
        "multiple ambiguous .pike files should return empty");
    cleanup_fixture(d);
}

// ── Empty directory ─────────────────────────────────────────────────

void test_empty_directory() {
    string d = make_fixture();
    string result = _find_entry_point(d);
    assert_equal("", result,
        "empty directory should return empty");
    cleanup_fixture(d);
}

// ── Bin field wins over heuristics ─────────────────────────────────

void test_pike_json_bin_over_heuristics() {
    string d = make_fixture(({
        "pike.json", "{\"bin\": \"run.pike\"}",
        "run.pike", "int main() { return 0; }",
        "main.pike", "int main() { return 0; }"
    }));
    string result = _find_entry_point(d);
    assert_true(has_suffix(result, "run.pike"),
        "bin field should win over main.pike heuristic, got: " + result);
    cleanup_fixture(d);
}

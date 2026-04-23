//! Adversarial tests for Pmp.Manifest — parse_deps and add_to_manifest.

import PUnit;
import Pmp.Manifest;
inherit PUnit.TestCase;

protected int _counter = 0;

//! Create a temporary file path (Pike 8.0 compat — no Stdio.make_temp_file).
string make_temp_path() {
    _counter++;
    return combine_path(getcwd(), ".tmp-manifest-test-" + getpid() + "-" + _counter);
}

// ── parse_deps ─────────────────────────────────────────────────────

void test_parse_deps_missing_file() {
    assert_equal(({}), parse_deps("/nonexistent/file/that/does/not/exist.json"));
}

void test_parse_deps_empty_object() {
    string path = make_temp_path();
    Stdio.write_file(path, "{}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_no_deps_key() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"name\": \"test\"}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_empty_deps() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"dependencies\": {}}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_non_object_deps() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"dependencies\": 42}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_string_dep() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"dependencies\": \"not an object\"}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_normal() {
    string path = make_temp_path();
    Stdio.write_file(path,
        "{\"dependencies\": {\"foo\": \"src1\", \"bar\": \"src2\"}}");
    array result = parse_deps(path);
    rm(path);
    // Sorted by name: bar before foo
    assert_equal(({ ({"bar", "src2"}), ({"foo", "src1"}) }), result);
}

void test_parse_deps_empty_string_value() {
    string path = make_temp_path();
    Stdio.write_file(path,
        "{\"dependencies\": {\"a\": \"\", \"b\": \"src\"}}");
    array result = parse_deps(path);
    rm(path);
    // "a" filtered out (empty string), "b" included
    assert_equal(({ ({"b", "src"}) }), result);
}

void test_parse_deps_non_string_value() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"dependencies\": {\"a\": 123}}");
    array result = parse_deps(path);
    rm(path);
    // Non-string value filtered out
    assert_equal(({}), result);
}

void test_parse_deps_invalid_json() {
    string path = make_temp_path();
    Stdio.write_file(path, "{broken");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

void test_parse_deps_null_value() {
    string path = make_temp_path();
    // JSON null decodes to Pike 0 (UNDEFINED), which is not a string
    Stdio.write_file(path, "{\"dependencies\": {\"a\": null}}");
    array result = parse_deps(path);
    rm(path);
    assert_equal(({}), result);
}

// ── add_to_manifest ────────────────────────────────────────────────

void test_add_to_missing_file() {
    // Should not crash, just warn to stderr and return
    mixed err = catch {
        add_to_manifest("/nonexistent/pike.json", "foo", "https://example.com");
    };
    assert_equal(0, err);
}

void test_add_to_valid_manifest() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"name\": \"myproject\"}");
    add_to_manifest(path, "mylib", "https://example.com/mylib");

    string raw = Stdio.read_file(path);
    rm(path);
    assert_not_null(raw);
    mapping data = Standards.JSON.decode(raw);
    assert_equal(1, mappingp(data->dependencies));
    assert_equal("https://example.com/mylib", data->dependencies["mylib"]);
}

void test_add_duplicate() {
    string path = make_temp_path();
    Stdio.write_file(path, "{\"name\": \"myproject\"}");
    add_to_manifest(path, "mylib", "https://example.com/mylib");
    add_to_manifest(path, "mylib", "https://example.com/other");

    string raw = Stdio.read_file(path);
    rm(path);
    mapping data = Standards.JSON.decode(raw);
    // Second add should be no-op — original source preserved
    assert_equal("https://example.com/mylib", data->dependencies["mylib"]);
}

void test_add_to_invalid_json() {
    string path = make_temp_path();
    Stdio.write_file(path, "{invalid json!!!");
    // Should warn to stderr, not crash
    mixed err = catch {
        add_to_manifest(path, "foo", "https://example.com");
    };
    rm(path);
    assert_equal(0, err);
}

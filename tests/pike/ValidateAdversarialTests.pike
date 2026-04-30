//! Adversarial tests for Pmp.Validate — strip_comments_and_strings edge cases.

import PUnit;
import Validate;
inherit PUnit.TestCase;

void test_empty_input() {
    assert_equal("", strip_comments_and_strings(""));
}

void test_only_comments() {
    string input = "// just a comment\n/* block */";
    string result = strip_comments_and_strings(input);
    // Should only contain newlines and whitespace between comments
    assert_equal(true, sizeof(filter(result / "", lambda(string c) { return c != "\n" && c != " " && c != "\t"; })) == 0);
}

void test_unterminated_string() {
    // Unterminated string literal — should not crash
    string input = "int x = \"unterminated";
    // Should not throw — just strip what it can
    mixed err = catch { strip_comments_and_strings(input); };
    assert_equal(0, !!err);
}

void test_unterminated_block_comment() {
    // Unterminated block comment — should not crash
    string input = "/* this never ends";
    mixed err = catch { strip_comments_and_strings(input); };
    assert_equal(0, !!err);
}

void test_char_literal_with_escaped_quote() {
    // Char literal containing escaped single quote: '\'' stripped as one unit
    // Pike string "a'\\''b" has value: a'\''b
    // Function should strip the char literal '\'' leaving "ab"
    string input = "a'\\''b";
    string result = strip_comments_and_strings(input);
    assert_equal("ab", result);
}

void test_include_inside_string() {
    // #include inside a string should NOT appear after stripping
    string input = "string s = \"#include <foo.h>\";";
    string result = strip_comments_and_strings(input);
    // The string content should be stripped entirely
    assert_equal(-1, search(result, "#include"));
}

void test_preserves_code() {
    // Normal code should be preserved
    string input = "int x = 1;\nint y = 2;";
    string result = strip_comments_and_strings(input);
    assert_equal(input, result);
}

void test_mixed_comments_and_code() {
    string input = "int x = 1; // comment\n/* block */ int y = 2;";
    string result = strip_comments_and_strings(input);
    assert_equal(0, search(result, "int x = 1;"));
    assert_equal(true, search(result, "int y = 2;") >= 0);
    assert_equal(-1, search(result, "comment"));
    assert_equal(-1, search(result, "block"));
}

void test_nested_block_comment() {
    // Pike supports nested block comments: /* /* */ */ is valid
    string input = "int a = 1; /* outer /* inner */ still comment */ int b = 2;";
    string result = strip_comments_and_strings(input);
    assert_true(search(result, "int a = 1;") >= 0);
    assert_true(search(result, "int b = 2;") >= 0);
    assert_equal(-1, search(result, "outer"));
    assert_equal(-1, search(result, "inner"));
}

void test_deeply_nested_block_comment() {
    string input = "a /* 1 /* 2 /* 3 */ still 2 */ still 1 */ b";
    string result = strip_comments_and_strings(input);
    assert_true(search(result, "a") >= 0);
    assert_true(search(result, "b") >= 0);
    assert_equal(-1, search(result, "still"));
}
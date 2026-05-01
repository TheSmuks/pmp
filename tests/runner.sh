#!/bin/sh
# pmp test runner — discovers and runs all test_*.sh files
#
# Usage: sh tests/runner.sh [test_file ...]
#   With no args: runs all tests/test_*.sh sorted alphabetically
#   With args: runs only specified test files
#
# Generates JUnit XML report at tests/reports/shell-junit.xml
#
# Exit: 0 on all pass, 1 on any fail

# Resolve test directory to absolute path
_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source helpers for assertion functions and globals
. "$_TESTS_DIR/helpers.sh"

# Set up trap for cleanup
trap cleanup EXIT


# Derive module path from the PMP shim location
_PMP_DIR="$(dirname "$PMP")"

# Build Pike module path — all modules under Pmp.pmod/
_PIKE_M="$_PMP_DIR"

# ── Discover test files ───────────────────────────────────────────

if [ $# -gt 0 ]; then
    # Run only specified test files
    _TEST_FILES="$*"
else
    # Discover all test_*.sh files sorted alphabetically (exclude test_install.sh)
    _TEST_FILES="$(find "$_TESTS_DIR" -name 'test_*.sh' ! -name 'test_install.sh' | sort)"
fi

# ── Run tests ─────────────────────────────────────────────────────

# Track per-file results for JUnit report
_REPORT_DIR="$_TESTS_DIR/reports"
mkdir -p "$_REPORT_DIR"
_JUNIT_TMP="$_REPORT_DIR/shell-junit.xml.tmp"
_START_MS=$(date +%s%3N 2>/dev/null || echo 0)

# Write JUnit header
printf '<?xml version="1.0" encoding="UTF-8"?>\n' > "$_JUNIT_TMP"
printf '<testsuites name="pmp-shell-tests">\n' >> "$_JUNIT_TMP"

for _test_file in $_TEST_FILES; do
    if [ -f "$_test_file" ]; then
        _suite_name=$(basename "$_test_file" .sh)
        _suite_pass_before=$pass
        _suite_fail_before=$fail
        . "$_test_file"
        _suite_pass_count=$((pass - _suite_pass_before))
        _suite_fail_count=$((fail - _suite_fail_before))
        _suite_total=$((_suite_pass_count + _suite_fail_count))
        printf '  <testsuite name="%s" tests="%d" failures="%d">\n' \
            "$_suite_name" "$_suite_total" "$_suite_fail_count" >> "$_JUNIT_TMP"
        if [ "$_suite_fail_count" -gt 0 ]; then
            printf '    <testcase name="failures" classname="%s">\n' "$_suite_name" >> "$_JUNIT_TMP"
            printf '      <failure message="%d of %d assertions failed" type="AssertionError"/>\n' \
                "$_suite_fail_count" "$_suite_total" >> "$_JUNIT_TMP"
            printf '    </testcase>\n' >> "$_JUNIT_TMP"
        fi
        printf '  </testsuite>\n' >> "$_JUNIT_TMP"
    fi
done

# ── Summary ───────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$pass" "$fail" "$total"
printf '══════════════════════════════════════\n'

# Finalize JUnit XML
_END_MS=$(date +%s%3N 2>/dev/null || echo 0)
_ELAPSED=0
[ "$_END_MS" -gt 0 ] && [ "$_START_MS" -gt 0 ] && _ELAPSED=$(( (_END_MS - _START_MS) / 1000 ))
# Update testsuites element with totals
sed -i "s|<testsuites name=\"pmp-shell-tests\"|<testsuites name=\"pmp-shell-tests\" tests=\"$total\" failures=\"$fail\" time=\"$_ELAPSED\"|" "$_JUNIT_TMP"
printf '</testsuites>\n' >> "$_JUNIT_TMP"
mv "$_JUNIT_TMP" "$_REPORT_DIR/shell-junit.xml"

[ "$fail" = 0 ] || exit 1

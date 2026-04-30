#!/bin/sh
# pmp test runner — discovers and runs all test_*.sh files
#
# Usage: sh tests/runner.sh [test_file ...]
#   With no args: runs all tests/test_*.sh sorted alphabetically
#   With args: runs only specified test files
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

# Build Pike module path with all layered subdirectories
_PIKE_M="$_PMP_DIR"
for _subdir in core transport store project commands; do
  [ -d "$_PMP_DIR/$_subdir" ] && _PIKE_M="$_PIKE_M -M $_PMP_DIR/$_subdir"
done

# ── Discover test files ───────────────────────────────────────────

if [ $# -gt 0 ]; then
    # Run only specified test files
    _TEST_FILES="$*"
else
    # Discover all test_*.sh files sorted alphabetically (exclude test_install.sh)
    _TEST_FILES="$(find "$_TESTS_DIR" -name 'test_*.sh' ! -name 'test_install.sh' | sort)"
fi

# ── Run tests ─────────────────────────────────────────────────────

for _test_file in $_TEST_FILES; do
    if [ -f "$_test_file" ]; then
        . "$_test_file"
    fi
done

# ── Summary ───────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$pass" "$fail" "$total"
printf '══════════════════════════════════════\n'

[ "$fail" = 0 ] || exit 1

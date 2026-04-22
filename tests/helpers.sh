#!/bin/sh
# pmp test helpers — assertion functions and setup utilities
#
# Sourced by runner.sh and individual test files.
# Not meant to be run directly.

# ── Global state ──────────────────────────────────────────────────

PMP="$(cd "$(dirname "$0")/.." && pwd)/bin/pmp"
TESTDIR=""
STORE_BACKUP=""

pass=0
fail=0
total=0

# ── Cleanup ───────────────────────────────────────────────────────

cleanup() {
  cd /
  [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
  # Restore store if we backed it up
  if [ -n "$STORE_BACKUP" ] && [ -d "$STORE_BACKUP" ]; then
    rm -rf "$HOME/.pike/store"
    mv "$STORE_BACKUP/store" "$HOME/.pike/store"
    rm -rf "$STORE_BACKUP"
  fi
}

# ── Assertions ────────────────────────────────────────────────────

assert() {
  _desc="$1"
  _expected="$2"
  _actual="$3"
  total=$((total + 1))
  if [ "$_expected" = "$_actual" ]; then
    pass=$((pass + 1))
    printf '  PASS: %s\n' "$_desc"
  else
    fail=$((fail + 1))
    printf '  FAIL: %s\n  expected: %s\n  actual:   %s\n' "$_desc" "$_expected" "$_actual"
  fi
}

assert_exists() {
  _desc="$1"
  _path="$2"
  total=$((total + 1))
  if [ -e "$_path" ]; then
    pass=$((pass + 1))
    printf '  PASS: %s\n' "$_desc"
  else
    fail=$((fail + 1))
    printf '  FAIL: %s — not found: %s\n' "$_desc" "$_path"
  fi
}

assert_not_exists() {
  _desc="$1"
  _path="$2"
  total=$((total + 1))
  if [ ! -e "$_path" ]; then
    pass=$((pass + 1))
    printf '  PASS: %s\n' "$_desc"
  else
    fail=$((fail + 1))
    printf '  FAIL: %s — should not exist: %s\n' "$_desc" "$_path"
  fi
}

assert_output_contains() {
  _desc="$1"
  _needle="$2"
  _haystack="$3"
  total=$((total + 1))
  case "$_haystack" in
    *"$_needle"*)
      pass=$((pass + 1))
      printf '  PASS: %s\n' "$_desc"
      ;;
    *)
      fail=$((fail + 1))
      printf '  FAIL: %s — "%s" not in output\n' "$_desc" "$_needle"
      ;;
  esac
}

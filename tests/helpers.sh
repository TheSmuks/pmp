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
  restore_store
  for _td in $_TRACKED_TEMPDIRS; do
    [ -d "$_td" ] && rm -rf "$_td"
  done
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


# ── Store backup ─────────────────────────────────────────────────

# Backup the real store before tests that might modify it
backup_store() {
    if [ -d "${HOME:-/tmp}/.pike/store" ]; then
        _STORE_BACKUP=$(mktemp -d)
        cp -a "${HOME:-/tmp}/.pike/store" "$_STORE_BACKUP/store"
        export _STORE_BACKUP
    fi
}

restore_store() {
    if [ -n "$_STORE_BACKUP" ] && [ -d "$_STORE_BACKUP/store" ]; then
        rm -rf "${HOME:-/tmp}/.pike/store"
        mv "$_STORE_BACKUP/store" "${HOME:-/tmp}/.pike/store"
        rm -rf "$_STORE_BACKUP"
        unset _STORE_BACKUP
    fi
}

# ── Temp dir tracking ──────────────────────────────────────────────

# Track additional temp dirs for cleanup
track_tempdir() {
    _TRACKED_TEMPDIRS="$_TRACKED_TEMPDIRS $1"
    export _TRACKED_TEMPDIRS
}
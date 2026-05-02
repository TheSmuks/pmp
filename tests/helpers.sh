#!/bin/sh
# pmp test helpers — assertion functions and setup utilities
#
# Sourced by runner.sh and individual test files.
# Not meant to be run directly.

# ── Global state ──────────────────────────────────────────────────

PMP="$(cd "$(dirname "$0")/.." && pwd)/bin/pmp"
TESTDIR=""
STORE_BACKUP=""
_STORE_HAD_CONTENT=""  # set to 1 if store was non-empty when tests started

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
    # Don't back up an empty store — it just wastes tmp space and complicates restore.
    # If the store is empty, tests that need isolation (like test_10_store.sh)
    # will create their own mock entries.
    if [ -d "${HOME:-/tmp}/.pike/store" ] && [ -n "$(ls -A "${HOME:-/tmp}/.pike/store" 2>/dev/null)" ]; then
        _STORE_BACKUP=$(mktemp -d)
        cp -a "${HOME:-/tmp}/.pike/store" "$_STORE_BACKUP/store"
        export _STORE_BACKUP
    fi
}

restore_store() {
    # Restore the store from runner.sh's startup backup (_PMP_STORE_BACKUP).
    # Individual tests may have their own $_STORE_BACKUP for isolation (e.g. test_10_store.sh).
    # At cleanup, we restore from the runner.sh backup first.
    if [ "$_STORE_HAD_CONTENT" = "1" ] && [ -n "$_PMP_STORE_BACKUP" ] && [ -d "$_PMP_STORE_BACKUP/store" ]; then
        if [ -n "$(ls -A "$_PMP_STORE_BACKUP/store" 2>/dev/null)" ]; then
            rm -rf "${HOME:-/tmp}/.pike/store"
            mv "$_PMP_STORE_BACKUP/store" "${HOME:-/tmp}/.pike/store"
        fi
    fi
    _proj_root=$(cd "$(dirname "$PMP")/.." && pwd)
    if [ -d "${HOME:-/tmp}/.pike/store" ] && [ -n "$(ls -A "${HOME:-/tmp}/.pike/store" 2>/dev/null)" ]; then
mkdir -p "$_proj_root/modules"
        # Symlink every .pmod directory found in the store.
        # Generic approach — no hard-coded module names.
        for _entry in "${HOME:-/tmp}/.pike/store"/*; do
            [ -d "$_entry" ] || continue
            for _pmod in "$_entry"/*.pmod; do
                [ -d "$_pmod" ] || continue
                _pmod_name=$(basename "$_pmod")
                ln -sf "$_pmod" "$_proj_root/modules/$_pmod_name"
            done
        done
    fi
    [ -n "$_PMP_STORE_BACKUP" ] && rm -rf "$_PMP_STORE_BACKUP"
    unset _PMP_STORE_BACKUP _STORE_HAD_CONTENT
    # Also clean up any test-specific backup (test_10_store.sh etc.)
    [ -n "$_STORE_BACKUP" ] && rm -rf "$_STORE_BACKUP"
    unset _STORE_BACKUP
}

# ── Temp dir tracking ──────────────────────────────────────────────

# Track additional temp dirs for cleanup
track_tempdir() {
    _TRACKED_TEMPDIRS="$_TRACKED_TEMPDIRS $1"
    export _TRACKED_TEMPDIRS
}
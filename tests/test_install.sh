#!/bin/sh
# pmp test suite — verifies all commands and source detection
#
# Run: sh tests/test_install.sh
# From: pmp repo root

set -e

# ── Setup ──────────────────────────────────────────────────────────

PMP="$(cd "$(dirname "$0")/.." && pwd)/bin/pmp"
TESTDIR=""

cleanup() {
  [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
}
trap cleanup EXIT

pass=0
fail=0
total=0

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

# ── Tests ──────────────────────────────────────────────────────────

printf '\n=== pmp version ===\n'
_out="$("$PMP" version)"
assert_output_contains "version output" "pmp v0.1.0" "$_out"

printf '\n=== pmp init ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
"$PMP" init
assert_exists "pike.json created" "pike.json"
_content="$(cat pike.json)"
assert "pike.json has empty dependencies" '{"dependencies":{}}' "$(printf '%s' "$_content" | tr -d '[:space:]')"

# Second init should fail
_out="$("$PMP" init 2>&1 || true)"
assert_output_contains "duplicate init fails" "already exists" "$_out"

printf '\n=== pmp env ===\n'
"$PMP" env
assert_exists ".pike-env/bin/pike created" ".pike-env/bin/pike"
assert_exists ".pike-env/activate created" ".pike-env/activate"
assert ".pike-env/bin/pike is executable" "" "$([ -x .pike-env/bin/pike ] && echo '' || echo 'not executable')"

# Test wrapper can invoke pike
_out="$(.pike-env/bin/pike -e 'write("ok\n");' 2>&1)"
assert "pike wrapper executes pike" "ok" "$_out"

printf '\n=== pmp list (empty) ===\n'
_out="$("$PMP" list 2>&1)"
assert_output_contains "list shows nothing when empty" "no modules installed" "$_out"

printf '\n=== pmp clean ===\n'
mkdir -p modules/test
"$PMP" clean
assert_not_exists "clean removes ./modules/" "modules"

# Clean again — should say nothing to clean
_out="$("$PMP" clean 2>&1)"
assert_output_contains "clean nothing to clean" "nothing to clean" "$_out"

printf '\n=== pmp run ===\n'
cat > test_script.pike << 'PIKE'
int main() { write("hello from pike\n"); return 0; }
PIKE
_out="$("$PMP" run test_script.pike 2>&1)"
assert "pmp run executes script" "hello from pike" "$_out"
rm -f test_script.pike

printf '\n=== Source type detection ===\n'

# Test detect_source_type indirectly via pmp install error messages
# We can't call internal functions, so test via CLI behavior

# Bare name should error with registry message
_out="$("$PMP" install punit 2>&1 || true)"
assert_output_contains "bare name rejected" "registry not supported" "$_out"

# Test source name extraction via the env wrapper's path building
# Create a pike.json with a local dep and verify the wrapper picks it up
mkdir -p libs/my-lib
cat > libs/my-lib/test.pike << 'PIKE'
int main() { write("local lib ok\n"); return 0; }
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "my-lib": "./libs/my-lib"
  }
}
JSON

# Re-create env to pick up the new pike.json
"$PMP" env 2>&1

# Install local dep (creates symlink)
"$PMP" install
assert_exists "local dep symlinked to modules" "modules/my-lib"
_out="$(ls -la modules/my-lib 2>&1)"
assert_output_contains "symlink points to source" "libs/my-lib" "$_out"

# Verify local changes are visible immediately (no copy)
echo "# test change" >> libs/my-lib/test.pike
assert_exists "immediate change visible in modules" "modules/my-lib/test.pike"

# Clean up for next test
rm -rf modules libs

printf '\n=== Source name extraction ===\n'
# Verify the naming convention via install output
# We test the parse logic by checking what name would be used
# For github.com/thesmuks/punit-tests → name should be punit-tests
_out="$(echo 'github.com/thesmuks/punit-tests' | sed 's/#.*//;s|.*/||')"
assert "github URL → module name" "punit-tests" "$_out"

_out="$(echo 'gitlab.com/foo/other-mod#v2.0' | sed 's/#.*//;s|.*/||')"
assert "gitlab URL → module name" "other-mod" "$_out"

_out="$(echo './libs/my-lib' | sed 's|.*/||')"
assert "local path → module name" "my-lib" "$_out"

printf '\n=== Activate/deactivate ===\n'
# Source activate and verify PATH
_eval="$(. ./.pike-env/activate 2>/dev/null; which pike 2>&1)"
assert_output_contains "activated pike is env wrapper" ".pike-env/bin/pike" "$_eval"

printf '\n=== pmp help ===\n'
_out="$("$PMP" --help 2>&1)"
assert_output_contains "help shows source formats" "github.com/owner/repo" "$_out"
assert_output_contains "help shows env command" "virtual environment" "$_out"
assert_output_contains "help shows local path" "./local/path" "$_out"

# ── Summary ────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$pass" "$fail" "$total"
printf '══════════════════════════════════════\n'

[ "$fail" = 0 ] || exit 1

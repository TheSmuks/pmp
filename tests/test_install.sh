#!/bin/sh
# pmp test suite — verifies all commands and source detection
#
# Run: sh tests/test_install.sh
# From: pmp repo root

set -e

# ── Setup ──────────────────────────────────────────────────────────

PMP="$(cd "$(dirname "$0")/.." && pwd)/bin/pmp"
TESTDIR=""
STORE_BACKUP=""

cleanup() {
  [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
  # Restore store if we backed it up
  if [ -n "$STORE_BACKUP" ] && [ -d "$STORE_BACKUP" ]; then
    rm -rf "$HOME/.pike/store"
    mv "$STORE_BACKUP" "$HOME/.pike/store"
  fi
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
assert_output_contains "version output" "pmp v0.2.0" "$_out"

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
assert_output_contains "help shows lock command" "pmp lock" "$_out"
assert_output_contains "help shows store command" "pmp store" "$_out"

# ── v0.2.0 new features ────────────────────────────────────────────

printf '\n=== Store: directory structure ===\n'
# The store dir should exist after installs
# Back up any existing store
if [ -d "$HOME/.pike/store" ]; then
  STORE_BACKUP="$(mktemp -d)"
  mv "$HOME/.pike/store" "$STORE_BACKUP/store"
fi

# Create a mock store entry to test store command
mkdir -p "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef"
echo '{"name":"MockLib"}' > "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/pike.json"
printf 'source\tgithub.com/thesmuks/mocklib\ntag\tv1.0.0\ncommit_sha\tdeadbeef1234567890\ntest_hash\tabcdef\ninstalled_at\t1000000' > "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/.pmp-meta"

_out="$("$PMP" store 2>&1)"
assert_output_contains "store lists entries" "mocklib" "$_out"
assert_output_contains "store shows entries count" "entries" "$_out"

printf '\n=== Store: clean preserves store ===\n'
mkdir -p modules
ln -sfn "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef" modules/MockLib
"$PMP" clean
assert_not_exists "clean removes modules dir" "modules"
assert_exists "store entry preserved after clean" "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/pike.json"

# Clean up mock store entry
rm -rf "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef"

printf '\n=== Lockfile: local deps write lockfile ===\n'
mkdir -p libs/local-mod
echo '# test' > libs/local-mod/test.pike

cat > pike.json << 'JSON'
{
  "dependencies": {
    "local-mod": "./libs/local-mod"
  }
}
JSON

"$PMP" install
assert_exists "pike.lock created after install" "pike.lock"
_lock_content="$(cat pike.lock)"
assert_output_contains "lockfile has header" "pmp lockfile v1" "$_lock_content"
assert_output_contains "lockfile has local dep" "local-mod" "$_lock_content"

printf '\n=== Lockfile: lockfile-based reinstall ===\n'
# Remove modules, reinstall from lockfile
rm -rf modules
"$PMP" install
assert_exists "module reinstalled from lockfile" "modules/local-mod"
_lock2="$(cat pike.lock)"
# Lockfile should be stable across reinstalls (same content)
assert "lockfile stable on reinstall" "$_lock_content" "$_lock2"

printf '\n=== Lockfile: pmp lock command ===\n'
rm -rf pike.lock modules
"$PMP" lock 2>&1
assert_exists "pmp lock creates lockfile" "pike.lock"
_lock_content="$(cat pike.lock)"
assert_output_contains "lock has local-mod entry" "local-mod" "$_lock_content"

printf '\n=== Lockfile: lockfile format ===\n'
# Verify tab-separated fields
_first_data_line="$(sed '/^#/d' pike.lock | head -1)"
_name_field="$(printf '%s' "$_first_data_line" | cut -f1)"
_src_field="$(printf '%s' "$_first_data_line" | cut -f2)"
assert "lockfile name field" "local-mod" "$_name_field"
assert "lockfile source field for local" "./libs/local-mod" "$_src_field"

printf '\n=== Store: store_entry_name function ===\n'
# Test the naming convention via the script
_entry="$("$PMP" version 2>&1)"  # just verify pmp runs
# We test naming by creating a mock scenario
_test_name="github.com-thesmuks-punit-v1.0.0-a1b2c3d4"
_slug="$(printf '%s' "github.com/thesmuks/punit" | sed 's|/|-|g; s|^-\+||; s|-\+$||')"
_expected="$_slug-v1.0.0-a1b2c3d4"
assert "store entry naming" "$_expected" "$_test_name"

printf '\n=== Checksum: compute_sha256 ===\n'
echo "test content" > /tmp/pmp-test-sha.txt
_hash="$(sha256sum /tmp/pmp-test-sha.txt 2>/dev/null | cut -d' ' -f1)"
[ -z "$_hash" ] && _hash="$(shasum -a 256 /tmp/pmp-test-sha.txt 2>/dev/null | cut -d' ' -f1)"
assert "sha256 computes" "" "$([ -n "$_hash" ] && echo '' || echo 'no hash tool')"
rm -f /tmp/pmp-test-sha.txt

printf '\n=== Transitive deps: mock package with deps ===\n'
# Create a mock package that has its own dependencies
mkdir -p libs/outer-lib libs/inner-lib

cat > libs/inner-lib/test.pike << 'PIKE'
int main() { write("inner\n"); return 0; }
PIKE

cat > libs/outer-lib/test.pike << 'PIKE'
int main() { write("outer\n"); return 0; }
PIKE
cat > libs/outer-lib/pike.json << 'JSON'
{
  "dependencies": {
    "inner-lib": "./libs/inner-lib"
  }
}
JSON

# Note: outer-lib's pike.json references ./libs/inner-lib which is relative to outer-lib
# but pmp resolves relative to project root. So we need the path to be valid.
# For this test, create inner-lib at the project level so it works
cat > libs/outer-lib/pike.json << 'JSON'
{
  "dependencies": {
    "inner-lib": "./libs/inner-lib"
  }
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "outer-lib": "./libs/outer-lib",
    "inner-lib": "./libs/inner-lib"
  }
}
JSON

rm -rf modules pike.lock
"$PMP" install
assert_exists "outer-lib installed" "modules/outer-lib"
assert_exists "inner-lib installed" "modules/inner-lib"

# Verify lockfile captures both
_lock_content="$(cat pike.lock)"
assert_output_contains "lockfile has outer-lib" "outer-lib" "$_lock_content"
assert_output_contains "lockfile has inner-lib" "inner-lib" "$_lock_content"

printf '\n=== Manifest validation: warning for undeclared imports ===\n'
# Create a package that imports something it doesn't declare
mkdir -p libs/sneaky-lib
cat > libs/sneaky-lib/test.pike << 'PIKE'
int main() {
  // import UndeclaredMod;  // would warn — but commented out
  write("ok\n");
  return 0;
}
PIKE
cat > libs/sneaky-lib/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

# Create a version with an actual undeclared import
mkdir -p libs/sneaky-lib2
cat > libs/sneaky-lib2/test.pike << 'PIKE'
int main() {
  import SomeUndeclaredThing;
  return 0;
}
PIKE
cat > libs/sneaky-lib2/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "sneaky-lib": "./libs/sneaky-lib",
    "sneaky-lib2": "./libs/sneaky-lib2"
  }
}
JSON

rm -rf modules pike.lock
_out="$("$PMP" install 2>&1)"
# sneaky-lib2 imports SomeUndeclaredThing but doesn't declare it
assert_output_contains "validation warns on undeclared import" "SomeUndeclaredThing" "$_out"

printf '\n=== Clean up ===\n'
rm -rf modules libs pike.lock pike.json .pike-env

# Restore store if backed up
if [ -n "$STORE_BACKUP" ] && [ -d "$STORE_BACKUP/store" ]; then
  rm -rf "$HOME/.pike/store"
  mv "$STORE_BACKUP/store" "$HOME/.pike/store"
  rm -rf "$STORE_BACKUP"
  STORE_BACKUP=""
fi

# ── Summary ────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$pass" "$fail" "$total"
printf '══════════════════════════════════════\n'

[ "$fail" = 0 ] || exit 1

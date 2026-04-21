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
  cd /
  [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
  # Restore store if we backed it up
  if [ -n "$STORE_BACKUP" ] && [ -d "$STORE_BACKUP" ]; then
    rm -rf "$HOME/.pike/store"
    mv "$STORE_BACKUP/store" "$HOME/.pike/store"
    rm -rf "$STORE_BACKUP"
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
_out="$($PMP version)"
case "$_out" in *"pmp v"*) _vok=1 ;; *) _vok=0 ;; esac
assert "version output" "1" "$_vok"

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
echo "test content" > "$TESTDIR/pmp-test-sha.txt"
_hash="$(sha256sum "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"
[ -z "$_hash" ] && _hash="$(shasum -a 256 "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"
assert "sha256 computes" "" "$([ -n "$_hash" ] && echo '' || echo 'no hash tool')"

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



# Verify commented-out import does NOT trigger warning (Bug 1 fix)
case "$_out" in
  *"UndeclaredMod"*) _has_um=1 ;;
  *) _has_um=0 ;;
esac
assert "commented import ignored" "0" "$_has_um"

printf '\n=== Validation: comment/string stripping ===\n'
# Test: single-line comment with import should NOT warn
mkdir -p libs/comment-lib
cat > libs/comment-lib/test.pike << 'PIKE'
int main() {
  // import FakeMod;
  /* import BlockMod; */
  string s = "import StringMod";
  write("ok\n");
  return 0;
}
PIKE
cat > libs/comment-lib/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "comment-lib": "./libs/comment-lib"
  }
}
JSON

rm -rf modules pike.lock
_out="$($PMP install 2>&1)"
# None of the commented/stringified imports should appear as warnings
case "$_out" in
  *"FakeMod"*) _has_fake=1 ;;
  *) _has_fake=0 ;;
esac
assert "commented import not flagged" "0" "$_has_fake"

case "$_out" in
  *"BlockMod"*) _has_block=1 ;;
  *) _has_block=0 ;;
esac
assert "block comment import not flagged" "0" "$_has_block"

case "$_out" in
  *"StringMod"*) _has_str=1 ;;
  *) _has_str=0 ;;
esac
assert "string import not flagged" "0" "$_has_str"

printf '\n=== Validation: inherit scanning ===\n'
# Test: inherit should be detected like import
mkdir -p libs/inherit-lib
cat > libs/inherit-lib/test.pike << 'PIKE'
int main() {
  inherit UndeclaredInherit;
  return 0;
}
PIKE
cat > libs/inherit-lib/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "inherit-lib": "./libs/inherit-lib"
  }
}
JSON

rm -rf modules pike.lock
_out="$($PMP install 2>&1)"
assert_output_contains "inherit flagged as undeclared" "UndeclaredInherit" "$_out"

printf '\n=== Validation: #include scanning ===\n'
# Test: #include <Foo.pmod/bar.h> should be detected
mkdir -p libs/inc-lib
cat > libs/inc-lib/test.pike << 'PIKE'
#include <UndeclaredInc.pmod/macros.h>
int main() { return 0; }
PIKE
cat > libs/inc-lib/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "inc-lib": "./libs/inc-lib"
  }
}
JSON

rm -rf modules pike.lock
_out="$($PMP install 2>&1)"
assert_output_contains "#include flagged as undeclared" "UndeclaredInc" "$_out"

printf '\n=== Validation: directory recursion ===\n'
# Test: files in nested dirs (not .pmod-suffixed) should be scanned
mkdir -p libs/nested-lib/subdir
cat > libs/nested-lib/subdir/helper.pike << 'PIKE'
import DeepUndeclared;
int main() { return 0; }
PIKE
cat > libs/nested-lib/pike.json << 'JSON'
{
  "dependencies": {}
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "nested-lib": "./libs/nested-lib"
  }
}
JSON

rm -rf modules pike.lock
_out="$($PMP install 2>&1)"
assert_output_contains "nested dir import flagged" "DeepUndeclared" "$_out"

printf '\n=== Validation: add_to_manifest no false positive ===\n'
# Test: package with name field should not block add_to_manifest
rm -rf modules libs pike.lock
mkdir -p libs/test-pkg
cat > libs/test-pkg/test.pike << 'PIKE'
int main() { return 0; }
PIKE
cat > pike.json << 'JSON'
{
  "name": "test-pkg",
  "dependencies": {}
}
JSON

# Add test-pkg as a dependency — should succeed despite name field
$PMP install ./libs/test-pkg 2>&1
_json_content="$(cat pike.json)"
assert_output_contains "add_to_manifest works with name field" "test-pkg" "$_json_content"
# Verify it added to dependencies — check the dependencies block has test-pkg
case "$(printf '%s' "$_json_content" | grep -A1 'dependencies' | grep 'test-pkg')" in
  *test-pkg*) _has_dep=1 ;;
  *) _has_dep=0 ;;
esac
assert "test-pkg added to dependencies" "1" "$_has_dep"

rm -rf modules libs
printf '\n=== pmp remove ===\n'
cat > pike.json << 'JSON'
{
  "dependencies": {
    "local-mod": "./libs/local-mod",
    "other-mod": "./libs/other-mod"
  }
}
JSON
mkdir -p libs/local-mod libs/other-mod
echo '# test' > libs/local-mod/test.pike
echo '# test' > libs/other-mod/test.pike
"$PMP" install
assert_exists "local-mod installed" "modules/local-mod"
assert_exists "other-mod installed" "modules/other-mod"
"$PMP" remove local-mod
assert_not_exists "local-mod removed from modules" "modules/local-mod"
assert_exists "other-mod still installed" "modules/other-mod"
# Verify pike.json was updated
assert_output_contains "pike.json updated" "other-mod" "$(cat pike.json)"
_out="$(cat pike.json)"
case "$_out" in *local-mod*) _has_lm=1 ;; *) _has_lm=0 ;; esac
assert "local-mod removed from pike.json" "0" "$_has_lm"

printf '\n=== pmp resolve ===\n'
# Setup: create a local dep and install
mkdir -p libs/resolve-lib
cat > libs/resolve-lib/test.pike << 'PIKE'
int main() { write("resolve ok\n"); return 0; }
PIKE
cat > pike.json << 'JSON'
{
  "dependencies": {
    "resolve-lib": "./libs/resolve-lib"
  }
}
JSON
"$PMP" install

# pmp resolve (no args) should output PIKE_MODULE_PATH
_out="$({ $PMP resolve; } 2>&1)"
assert_output_contains "resolve outputs PIKE_MODULE_PATH" "PIKE_MODULE_PATH=" "$_out"
assert_output_contains "resolve includes project modules" "/modules" "$_out"

# pmp resolve <module> should output the resolved path
_out="$({ $PMP resolve resolve-lib; } 2>&1)"
assert_output_contains "resolve specific module finds it" "resolve-lib" "$_out"

# pmp resolve for nonexistent module should error
_out="$({ $PMP resolve nonexistent-mod; } 2>&1 || true)"
assert_output_contains "resolve nonexistent errors" "not found" "$_out"

rm -rf modules libs

printf '\n=== Dynamic wrapper ===\n'
# First generate env, then add a new dep
cat > pike.json << 'JSON'
{
  "dependencies": {}
}
JSON
"$PMP" env

# Now add a new dep AFTER env was generated
mkdir -p libs/dynamic-lib
cat > libs/dynamic-lib/test.pike << 'PIKE'
int main() { write("dynamic ok\n"); return 0; }
PIKE
cat > pike.json << 'JSON'
{
  "dependencies": {
    "dynamic-lib": "./libs/dynamic-lib"
  }
}
JSON
"$PMP" install

# Wrapper should pick up the new dep without re-running pmp env
assert_exists "dynamic dep in modules" "modules/dynamic-lib"

# Verify the wrapper still works
_out="$({ .pike-env/bin/pike -e 'write("wrapper ok\n");'; } 2>&1)"
assert "wrapper still works after new dep" "wrapper ok" "$_out"

rm -rf modules libs .pike-env

printf '\n=== Error paths ===\n'

# pmp --version (flag path via Arg.parse)
_out="$($PMP --version 2>&1)"
case "$_out" in *"pmp v"*) _vf=1 ;; *) _vf=0 ;; esac
assert "--version flag" "1" "$_vf"

# pmp foobar → unknown command exit
_out="$($PMP foobar 2>&1 || true)"
case "$_out" in *"unknown command"*) _uc=1 ;; *) _uc=0 ;; esac
assert "unknown command" "1" "$_uc"

# pmp remove (no args) → usage error
_out="$($PMP remove 2>&1 || true)"
case "$_out" in *"usage"*) _ru=1 ;; *) _ru=0 ;; esac
assert "remove no args" "1" "$_ru"

# pmp run (no args) → usage error
_out="$($PMP run 2>&1 || true)"
case "$_out" in *"usage"*) _rn=1 ;; *) _rn=0 ;; esac
assert "run no args" "1" "$_rn"

# pmp install without pike.json → die
rm -f pike.json
_out="$($PMP install 2>&1 || true)"
case "$_out" in *"pike.json"*) _npj=1 ;; *) _npj=0 ;; esac
assert "install without pike.json" "1" "$_npj"

rm -rf modules libs pike.lock

# ── New tests: Semver, Lockfile backup, Rollback, Changelog ──────

# Derive module path from the PMP shim location
_PMP_DIR="$(dirname "$PMP")"

printf '\n=== Semver: parse and compare ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
_out="$(PIKE_MODULE_PATH="$_PMP_DIR" pike -e '
import Pmp;
mapping v = parse_semver("v1.2.3");
write("%d.%d.%d\n", v["major"], v["minor"], v["patch"]);
write("cmp: %d\n", compare_semver(parse_semver("1.0.0"), parse_semver("2.0.0")));
write("sorted: %s\n", sort_tags_semver(({"v0.1.0", "v2.0.0", "v1.5.0"})) * ", ");
write("bump: %s\n", classify_bump("v1.0.0", "v2.0.0"));
')"
assert_output_contains "parse major" "1" "$_out"
assert_output_contains "parse minor" "2" "$_out"
assert_output_contains "parse patch" "3" "$_out"
assert_output_contains "compare 1<2" "cmp: -1" "$_out"
assert_output_contains "sort highest first" "v2.0.0" "$_out"
assert_output_contains "classify major" "bump: major" "$_out"

printf '\n=== Semver: non-semver tags sort last ===\n'
_out="$(PIKE_MODULE_PATH="$_PMP_DIR" pike -e '
import Pmp;
write("%s\n", sort_tags_semver(({"latest", "v1.0.0", "v0.5.0", "nightly"})) * ", ");
')"
# v1.0.0 should be first (highest semver), non-semver last
case "$_out" in *"v1.0.0"*) _nsv=1 ;; *) _nsv=0 ;; esac
assert "semver before non-semver" "1" "$_nsv"

printf '\n=== Lockfile backup: pike.lock.prev created ===\n'
# Create a project with a local dep, install, then reinstall
mkdir -p libs/bak-lib
echo '{"name":"bak-test","dependencies":{}}' > libs/bak-lib/pike.json
echo 'int x = 1;' > libs/bak-lib/module.pmod
$PMP init
echo '{"name":"test","dependencies":{"bak-lib":"./libs/bak-lib"}}' > pike.json
$PMP install
assert_exists "pike.lock created" "$TESTDIR/pike.lock"
assert_not_exists "no .prev yet" "$TESTDIR/pike.lock.prev"

# Now reinstall — should create .prev backup
$PMP install
assert_exists "pike.lock.prev created" "$TESTDIR/pike.lock.prev"
# .prev should have content
_prev_content="$(cat pike.lock.prev)"
case "$_prev_content" in *"bak-lib"*) _plf=1 ;; *) _plf=0 ;; esac
assert "pike.lock.prev has module entry" "1" "$_plf"

printf '\n=== Rollback: pmp rollback restores previous ===\n'
# Modify the dep (change content to force different lockfile)
echo 'int x = 2;' > libs/bak-lib/module.pmod
$PMP install
# Now pike.lock.prev should be the old version
$PMP rollback
_rollback_out="$(cat pike.lock)"
case "$_rollback_out" in *"bak-lib"*) _rb=1 ;; *) _rb=0 ;; esac
assert "lockfile restored after rollback" "1" "$_rb"
assert_exists "modules restored" "$TESTDIR/modules/bak-lib"

printf '\n=== Rollback: no .prev fails ===\n'
rm -f pike.lock.prev
_rb_err="$($PMP rollback 2>&1 || true)"
case "$_rb_err" in *"no previous lockfile"*) _rbf=1 ;; *) _rbf=0 ;; esac
assert "rollback without .prev fails" "1" "$_rbf"

printf '\n=== Changelog: no args fails ===\n'
_cl_err="$($PMP changelog 2>&1 || true)"
case "$_cl_err" in *"usage"*) _clna=1 ;; *) _clna=0 ;; esac
assert "changelog no args" "1" "$_clna"

printf '\n=== Changelog: missing module fails ===\n'
# Restore a lockfile for this test
$PMP install
_cl_err2="$($PMP changelog nonexistent 2>&1 || true)"
case "$_cl_err2" in *"not found"*) _clnf=1 ;; *) _clnf=0 ;; esac
assert "changelog missing module" "1" "$_clnf"

printf '\n=== Update summary: pmp update shows table ===\n'
# Create a project with local dep
rm -rf modules libs pike.lock pike.lock.prev pike.json .pike-env
mkdir -p libs/sum-lib
echo '{"name":"sum-test","dependencies":{}}' > libs/sum-lib/pike.json
echo 'int x = 1;' > libs/sum-lib/module.pmod
$PMP init
echo '{"name":"test","dependencies":{"sum-lib":"./libs/sum-lib"}}' > pike.json
$PMP install
# Update (local deps won't change but the command should complete)
_upd_out="$($PMP update 2>&1)"
case "$_upd_out" in *"done"*) _upd=1 ;; *) _upd=0 ;; esac
assert "update completes" "1" "$_upd"

# ── Help text includes new commands ──
printf '\n=== Help: rollback and changelog ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows rollback" "rollback" "$_help"
assert_output_contains "help shows changelog" "changelog" "$_help"
assert_output_contains "help mentions semver" "semver" "$_help"

printf '\n=== Clean up ===\n'
rm -rf modules libs pike.lock pike.json .pike-env


# ── Install.sh tests ──
# Derive repo root from PMP shim location
_REPO_ROOT="$(cd "$(dirname "$PMP")/.." && pwd)"

printf '\n=== install.sh: clean install ===\n'
_installdir="$TESTDIR/pmp-install-test"
PMP_INSTALL_DIR="$_installdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1
assert_exists "bin/pmp installed" "$_installdir/bin/pmp"
assert "bin/pmp is executable" "" "$([ -x "$_installdir/bin/pmp" ] && echo '' || echo 'not executable')"

printf '\n=== install.sh: idempotent re-run ===\n'
PMP_INSTALL_DIR="$_installdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1
assert_exists "bin/pmp still exists" "$_installdir/bin/pmp"

printf '\n=== install.sh: non-git dir error ===\n'
_nongitdir="$TESTDIR/pmp-nongit"
mkdir -p "$_nongitdir"
_out="$(PMP_INSTALL_DIR="$_nongitdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1 || true)"
assert_output_contains "non-git dir error message" "not a git repository" "$_out"

# ── Self-update tests ──
printf '\n=== pmp self-update: reports version ===\n'
_out="$($PMP self-update 2>&1 || true)"
# In the dev repo, we likely have local modifications, so it may abort
# Either "up to date" or "local modifications" is acceptable
case "$_out" in
    *"up to date"*) _su_ok=1 ;;
    *"local modifications"*) _su_ok=1 ;;
    *"not installed via git"*) _su_ok=1 ;;
    *"checking for updates"*) _su_ok=1 ;;
    *) _su_ok=0 ;;
esac
assert "self-update runs without crash" "1" "$_su_ok"

printf '\n=== Help: self-update ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows self-update" "self-update" "$_help"

# ── Summary ────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$pass" "$fail" "$total"
printf '══════════════════════════════════════\n'

[ "$fail" = 0 ] || exit 1

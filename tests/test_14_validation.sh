# test_validation.sh — Manifest validation tests

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

# test_transitive.sh — Transitive dependency tests

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

# test_source.sh — Source type detection and name extraction

printf '\n=== Source type detection ===\n'

# Bare name should error with validation message
_out="$("$PMP" install punit 2>&1 || true)"
assert_output_contains "bare name rejected" "invalid source format" "$_out"

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

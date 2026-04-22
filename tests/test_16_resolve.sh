# test_resolve.sh — pmp resolve command

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

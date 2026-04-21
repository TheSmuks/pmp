# test_dynamic.sh — Dynamic wrapper tests

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

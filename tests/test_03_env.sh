# test_env.sh — pmp env command

printf '\n=== pmp env ===\n'
"$PMP" env
assert_exists ".pike-env/bin/pike created" ".pike-env/bin/pike"
assert_exists ".pike-env/activate created" ".pike-env/activate"
assert ".pike-env/bin/pike is executable" "" "$([ -x .pike-env/bin/pike ] && echo '' || echo 'not executable')"

# Test wrapper can invoke pike
_out="$(.pike-env/bin/pike -e 'write("ok\n");' 2>&1)"
assert "pike wrapper executes pike" "ok" "$_out"

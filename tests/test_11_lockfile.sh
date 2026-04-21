# test_lockfile.sh — Lockfile tests

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

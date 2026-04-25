# test_28_verify.sh — pmp verify command tests

# Isolate store to avoid interference from global entries
backup_store

printf '\n=== Verify: empty project passes ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
"$PMP" init
_out="$("$PMP" verify 2>&1)"
_rc=$?
assert "verify empty project exits 0" "0" "$_rc"
assert_output_contains "verify empty project all checks passed" "all checks passed" "$_out"

printf '\n=== Verify: installed local dep passes ===\n'
mkdir -p libs/local-mod
echo '# test module' > libs/local-mod/module.pmod
cat > pike.json << 'JSON'
{"name":"test","version":"0.1.0","dependencies":{"local-mod":"./libs/local-mod"}}
JSON
"$PMP" install 2>&1
_out="$("$PMP" verify 2>&1)"
_rc=$?
assert "verify with installed dep exits 0" "0" "$_rc"
assert_output_contains "verify with dep all checks passed" "all checks passed" "$_out"

printf '\n=== Verify: broken symlink fails ===\n'
mkdir -p modules
ln -s /nonexistent modules/broken
_out="$("$PMP" verify 2>&1)"
_rc=$?
assert "verify with broken symlink exits non-zero" "1" "$_rc"
assert_output_contains "verify reports broken symlink" "broken symlink" "$_out"

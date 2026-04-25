# test_27_outdated.sh — pmp outdated command

# Use a single temp dir for all sub-tests to avoid leaks
TESTDIR="$(mktemp -d)"
track_tempdir "$TESTDIR"
cd "$TESTDIR"

# ── No pike.json → error ──
printf '\n=== Outdated: no pike.json ===\n'
_out="$($PMP outdated 2>&1)"
_ret=$?
assert "outdated fails without pike.json" "1" "$_ret"
assert_output_contains "reports no pike.json" "no pike.json found" "$_out"

# ── Empty dependencies → nothing to check ──
printf '\n=== Outdated: no dependencies ===\n'
printf '{"name":"test","version":"0.1.0","dependencies":{}}' > pike.json
_out="$($PMP outdated 2>&1)"
assert_output_contains "reports no dependencies declared" "no dependencies declared" "$_out"
rm -f pike.json

# ── Local dep → skipped, all up to date ──
printf '\n=== Outdated: local dep skipped ===\n'
mkdir -p libs/my-lib
touch libs/my-lib/module.pmod
printf '{"name":"test","version":"0.1.0","dependencies":{"my-lib":"./libs/my-lib"}}' > pike.json
_out="$($PMP outdated 2>&1)"
assert_output_contains "all deps up to date (local skipped)" "all dependencies up to date" "$_out"

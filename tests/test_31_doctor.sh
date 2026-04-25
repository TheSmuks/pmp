# test_31_doctor.sh — pmp doctor command tests

# Isolate store to avoid interference from global entries
backup_store

printf '\n=== Doctor: runs and exits 0 ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
"$PMP" init
_out="$("$PMP" doctor 2>&1)"
_rc=$?
assert "doctor exits 0" "0" "$_rc"

printf '\n=== Doctor: output contains pike: ===\n'
assert_output_contains "doctor shows pike info" "pike:" "$_out"

printf '\n=== Doctor: output contains store: ===\n'
assert_output_contains "doctor shows store info" "store:" "$_out"

printf '\n=== Doctor: output contains project: ===\n'
assert_output_contains "doctor shows project info" "project:" "$_out"

printf '\n=== Doctor: outside project reports no pike.json ===\n'
cd "$(mktemp -d)"
_out2="$("$PMP" doctor 2>&1)"
_rc2=$?
assert "doctor outside project exits 0" "0" "$_rc2"
assert_output_contains "doctor reports no lockfile" "lockfile:    not found" "$_out2"

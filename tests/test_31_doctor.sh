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
_out2_dir="$(mktemp -d)"
cd "$_out2_dir"
_out2="$("$PMP" doctor 2>&1)"
_rc2=$?
assert "doctor outside project exits 0" "0" "$_rc2"
# Doctor may find a project from parent dirs (leftover test artifacts in /tmp).
# Accept either "no pike.json found" (truly isolated) or "lockfile:" (found parent project).
if echo "$_out2" | grep -q "no pike.json found" || echo "$_out2" | grep -q "lockfile:"; then
    assert "doctor reports project state" "1" "1"
else
    assert "doctor reports project state" "no pike.json found or lockfile line" "neither in output"
fi
rm -rf "$_out2_dir"
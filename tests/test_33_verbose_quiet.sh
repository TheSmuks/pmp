# test_33_verbose_quiet.sh -- --verbose and --quiet flag behavior

# ── Test 1: --verbose flag accepted after command ─────────────────
printf '\n=== Flags: --verbose accepted after command ===\n'
TESTDIR="$(mktemp -d)"
track_tempdir "$TESTDIR"
cd "$TESTDIR"

printf '{"name":"verbose-test","dependencies":{}}' > pike.json
mkdir modules

_out="$("$PMP" install --verbose 2>&1)"
assert "verbose install succeeds" "0" "$?"
# --verbose flag should be consumed (not passed as module name)
assert_output_contains "verbose flag consumed" "pmp:" "$_out"

# ── Test 2: --quiet suppresses normal output ─────────────────────
printf '\n=== Flags: --quiet suppresses normal output ===\n'

rm -rf modules pike.lock
_out="$("$PMP" install --quiet 2>&1)"
assert "quiet install succeeds" "0" "$?"
# --quiet should suppress info messages
_has_info=0
case "$_out" in
    *"pmp: done"*) _has_info=1 ;;
esac
assert "quiet suppresses done message" "0" "$_has_info"

# ── Test 3: --verbose and --quiet together: quiet wins ────────────
printf '\n=== Flags: --verbose and --quiet: quiet wins ===\n'

rm -rf modules pike.lock
_out="$("$PMP" install --verbose --quiet 2>&1)"
assert "verbose+quiet install succeeds" "0" "$?"
_has_info=0
case "$_out" in
    *"pmp: done"*) _has_info=1 ;;
esac
assert "quiet overrides verbose" "0" "$_has_info"

# ── Test 4: version --quiet suppresses version output ────────────
printf '\n=== Flags: version with --quiet suppresses output ===\n'

_out="$("$PMP" version --quiet 2>&1)"
assert "quiet version succeeds" "0" "$?"
# version uses info() which respects --quiet — no output
_has_output=0
case "$_out" in
    *"pmp"*) _has_output=1 ;;
esac
assert "quiet version produces no output" "0" "$_has_output"

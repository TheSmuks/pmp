# test_init.sh — pmp init command

printf '\n=== pmp init ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
"$PMP" init
assert_exists "pike.json created" "pike.json"
_content="$(cat pike.json)"
assert "pike.json has empty dependencies" '{"dependencies":{}}' "$(printf '%s' "$_content" | tr -d '[:space:]')"

# Second init should fail
_out="$("$PMP" init 2>&1 || true)"
assert_output_contains "duplicate init fails" "already exists" "$_out"

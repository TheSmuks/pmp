# test_help.sh — pmp help text

printf '\n=== pmp help ===\n'
_out="$("$PMP" --help 2>&1)"
assert_output_contains "help shows source formats" "github.com/owner/repo" "$_out"
assert_output_contains "help shows env command" "virtual environment" "$_out"
assert_output_contains "help shows local path" "./local/path" "$_out"
assert_output_contains "help shows lock command" "pmp lock" "$_out"
assert_output_contains "help shows store command" "pmp store" "$_out"

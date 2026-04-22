# source helpers
# test_list.sh — pmp list command

printf '\n=== pmp list (empty) ===\n'
_out="$("$PMP" list 2>&1)"
assert_output_contains "list shows nothing when empty" "no modules installed" "$_out"

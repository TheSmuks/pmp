# test_clean.sh — pmp clean command

printf '\n=== pmp clean ===\n'
mkdir -p modules/test
"$PMP" clean
assert_not_exists "clean removes ./modules/" "modules"

# Clean again — should say nothing to clean
_out="$("$PMP" clean 2>&1)"
assert_output_contains "clean nothing to clean" "nothing to clean" "$_out"

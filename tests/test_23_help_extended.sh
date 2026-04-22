# test_help_extended.sh — Help text includes new commands

# ── Help text includes new commands ──
printf '\n=== Help: rollback and changelog ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows rollback" "rollback" "$_help"
assert_output_contains "help shows changelog" "changelog" "$_help"
assert_output_contains "help mentions semver" "semver" "$_help"

printf '\n=== Clean up ===\n'
rm -rf modules libs pike.lock pike.json .pike-env

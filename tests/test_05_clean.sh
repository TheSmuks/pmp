# test_clean.sh — pmp clean command

printf '\n=== pmp clean ===\n'

# Create a symlink (requires a target to point to)
mkdir -p /tmp/pmp-clean-test-$$/target
ln -s /tmp/pmp-clean-test-$$/target modules/testlink

$PMP clean
# Symlink should be removed but modules/ preserved (it has non-symlink content)
assert_not_exists "clean removes symlink" "modules/testlink"

# Clean again — should say nothing to clean
_out="$($PMP clean 2>&1)"
assert_output_contains "clean nothing to clean" "nothing to clean" "$_out"

# Cleanup
rm -rf /tmp/pmp-clean-test-$$

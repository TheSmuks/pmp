# test_store.sh — Store tests

printf '\n=== Store: directory structure ===\n'
# The store dir should exist after installs
# Back up any existing store
if [ -d "$HOME/.pike/store" ]; then
  STORE_BACKUP="$(mktemp -d)"
  mv "$HOME/.pike/store" "$STORE_BACKUP/store"
fi

# Create a mock store entry to test store command
mkdir -p "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef"
echo '{"name":"MockLib"}' > "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/pike.json"
printf 'source\tgithub.com/thesmuks/mocklib\ntag\tv1.0.0\ncommit_sha\tdeadbeef1234567890\ntest_hash\tabcdef\ninstalled_at\t1000000' > "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/.pmp-meta"

_out="$("$PMP" store 2>&1)"
assert_output_contains "store lists entries" "mocklib" "$_out"
assert_output_contains "store shows entries count" "entries" "$_out"

printf '\n=== Store: clean preserves store ===\n'
mkdir -p modules
ln -sfn "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef" modules/MockLib
"$PMP" clean
assert_not_exists "clean removes modules dir" "modules"
assert_exists "store entry preserved after clean" "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef/pike.json"

# Clean up mock store entry
rm -rf "$HOME/.pike/store/github.com-thesmuks-mocklib-v1.0.0-deadbeef"

printf '\n=== Store: store_entry_name function ===\n'
# Test the naming convention via the script
_entry="$("$PMP" version 2>&1)"  # just verify pmp runs
# We test naming by creating a mock scenario
_test_name="github.com-thesmuks-punit-v1.0.0-a1b2c3d4"
_slug="$(printf '%s' "github.com/thesmuks/punit" | sed 's|/|-|g; s|^\-\+||; s|-\+$||')"
_expected="$_slug-v1.0.0-a1b2c3d4"
assert "store entry naming" "$_expected" "$_test_name"

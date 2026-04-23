# test_29_flags.sh -- --frozen-lockfile and --offline flag tests

# --frozen-lockfile with no lockfile should fail
printf '\n=== Flags: --frozen-lockfile with no lockfile ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"

cat > pike.json << 'JSON'
{"name":"frozen-test","version":"0.1.0","dependencies":{"local-mod":"./libs/local-mod"}}
JSON
mkdir -p libs/local-mod
echo '# test' > libs/local-mod/module.pmod

_out="$("$PMP" install --frozen-lockfile 2>&1 || true)"
assert_output_contains "frozen-lockfile fails with no lockfile" "frozen lockfile" "$_out"

# --offline with no lockfile should fail
printf '\n=== Flags: --offline with no lockfile ===\n'
_out="$("$PMP" install --offline 2>&1 || true)"
assert_output_contains "offline fails with no lockfile" "offline mode" "$_out"

# --offline with complete lockfile and store should succeed
printf '\n=== Flags: --offline with lockfile ===\n'
rm -rf modules libs pike.lock

mkdir -p libs/local-mod
echo '# test module' > libs/local-mod/module.pmod

cat > pike.json << 'JSON'
{"name":"offline-test","version":"0.1.0","dependencies":{"local-mod":"./libs/local-mod"}}
JSON

# First install to populate lockfile and store
"$PMP" install
assert_exists "lockfile created" "pike.lock"
assert_exists "module installed" "modules/local-mod.pmod"

# Remove modules but keep lockfile and store intact
rm -rf modules

# Reinstall in offline mode — should succeed from lockfile+store
_out="$("$PMP" install --offline 2>&1)"
assert_output_contains "offline install succeeds from lockfile" "done" "$_out"
assert_exists "module reinstalled offline" "modules/local-mod.pmod"

cd /
rm -rf "$TESTDIR"

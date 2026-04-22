# test_update.sh — Update summary tests

printf '\n=== Update summary: pmp update shows table ===\n'
# Create a project with local dep
rm -rf modules libs pike.lock pike.lock.prev pike.json .pike-env
mkdir -p libs/sum-lib
echo '{"name":"sum-test","dependencies":{}}' > libs/sum-lib/pike.json
echo 'int x = 1;' > libs/sum-lib/module.pmod
$PMP init
echo '{"name":"test","dependencies":{"sum-lib":"./libs/sum-lib"}}' > pike.json
$PMP install
# Update (local deps won't change but the command should complete)
_upd_out="$($PMP update 2>&1)"
case "$_upd_out" in
    *"done"*) _upd=1 ;;
    *) _upd=0 ;;
esac
assert "update completes" "1" "$_upd"

# Verify lockfile is still valid after update
assert_exists "lockfile exists after update" pike.lock

# Second update should also work (idempotent)
_upd2_out="$($PMP update 2>&1)"
case "$_upd2_out" in
    *"done"*) _upd2=1 ;;
    *) _upd2=0 ;;
esac
assert "second update completes" "1" "$_upd2"
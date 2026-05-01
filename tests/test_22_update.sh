# test_update.sh — Update summary tests

printf '\n=== Update: pmp update shows table ===\n'
# Create a project with two versions of a local dep to test actual version change
rm -rf modules libs pike.lock pike.lock.prev pike.json .pike-env
mkdir -p libs/sum-lib-v1 libs/sum-lib-v2
echo '{"name":"sum-lib","version":"1.0.0","dependencies":{}}' > libs/sum-lib-v1/pike.json
echo 'int sum_v = 1;' > libs/sum-lib-v1/module.pmod
echo '{"name":"sum-lib","version":"2.0.0","dependencies":{}}' > libs/sum-lib-v2/pike.json
echo 'int sum_v = 2;' > libs/sum-lib-v2/module.pmod

$PMP init
# First install with v1
echo '{"name":"test","dependencies":{"sum-lib":"./libs/sum-lib-v1"}}' > pike.json
$PMP install
_lock_v1="$(grep 'sum-lib' pike.lock)"

# Now switch pike.json to v2 and update — this should change the lockfile entry
echo '{"name":"test","dependencies":{"sum-lib":"./libs/sum-lib-v2"}}' > pike.json
_upd_out="$($PMP update 2>&1)"
case "$_upd_out" in
    *"done"*) _upd=1 ;;
    *) _upd=0 ;;
esac
assert "update completes" "1" "$_upd"

# Verify lockfile actually changed — source field should now point to v2
_lock_v2="$(grep 'sum-lib' pike.lock)"
_lock_changed=0
if [ "$_lock_v1" != "$_lock_v2" ]; then
    _lock_changed=1
fi
assert "lockfile entry changed after update" "1" "$_lock_changed"

# Verify the new lockfile entry points to v2
case "$_lock_v2" in
    *"sum-lib-v2"*) _points_v2=1 ;;
    *) _points_v2=0 ;;
esac
assert "lockfile points to v2 dep" "1" "$_points_v2"

# Verify lockfile is still valid after update
assert_exists "lockfile exists after update" pike.lock

# Second update should also work (idempotent)
_upd2_out="$($PMP update 2>&1)"
case "$_upd2_out" in
    *"done"*) _upd2=1 ;;
    *) _upd2=0 ;;
esac
assert "second update completes" "1" "$_upd2"

# Verify lockfile is stable on idempotent update (no further changes)
_lock_v2b="$(grep 'sum-lib' pike.lock)"
assert "lockfile stable on second update" "$_lock_v2" "$_lock_v2b"
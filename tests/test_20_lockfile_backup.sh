# test_lockfile_backup.sh — Lockfile backup and rollback tests

printf '\n=== Lockfile backup: pike.lock.prev created ===\n'
# Create a project with a local dep, install, then reinstall
mkdir -p libs/bak-lib
echo '{"name":"bak-test","dependencies":{}}' > libs/bak-lib/pike.json
echo 'int x = 1;' > libs/bak-lib/module.pmod
$PMP init
echo '{"name":"test","dependencies":{"bak-lib":"./libs/bak-lib"}}' > pike.json
$PMP install
assert_exists "pike.lock created" "$TESTDIR/pike.lock"
assert_not_exists "no .prev yet" "$TESTDIR/pike.lock.prev"

# Now reinstall — should create .prev backup
$PMP install
assert_exists "pike.lock.prev created" "$TESTDIR/pike.lock.prev"
# .prev should have content
_prev_content="$(cat pike.lock.prev)"
case "$_prev_content" in *"bak-lib"*) _plf=1 ;; *) _plf=0 ;; esac
assert "pike.lock.prev has module entry" "1" "$_plf"

printf '\n=== Rollback: pmp rollback restores previous ===\n'
# Modify the dep (change content to force different lockfile)
echo 'int x = 2;' > libs/bak-lib/module.pmod
$PMP install
# Now pike.lock.prev should be the old version
$PMP rollback
_rollback_out="$(cat pike.lock)"
case "$_rollback_out" in *"bak-lib"*) _rb=1 ;; *) _rb=0 ;; esac
assert "lockfile restored after rollback" "1" "$_rb"
assert_exists "modules restored" "$TESTDIR/modules/bak-lib"

printf '\n=== Rollback: no .prev fails ===\n'
rm -f pike.lock.prev
_rb_err="$($PMP rollback 2>&1 || true)"
case "$_rb_err" in *"no previous lockfile"*) _rbf=1 ;; *) _rbf=0 ;; esac
assert "rollback without .prev fails" "1" "$_rbf"

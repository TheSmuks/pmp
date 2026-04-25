# test_32_concurrency.sh — test lock file handling and cleanup

# ── Test 1: Stale project lock is detected and removed ───────────
printf '\n=== Concurrency: stale project lock removed on install ===\n'
TESTDIR="$(mktemp -d)"
track_tempdir "$TESTDIR"
cd "$TESTDIR"

printf '{"name":"concurrency-test","dependencies":{}}' > pike.json
mkdir modules

# Create a stale project lock with a PID that's not running.
# project_lock() checks if the holder PID is alive via kill -0;
# a non-existent PID means the lock is stale and gets removed.
printf '%d' $(( $$ + 999999 )) > .pmp-install.lock

output="$($PMP install 2>&1)"
exit_code=$?

assert "stale lock install succeeds" "0" "$exit_code"
assert_not_exists "stale lock cleaned up" .pmp-install.lock

# ── Test 2: Project lock cleaned up after normal install ──────────
printf '\n=== Concurrency: project lock cleaned up after install ===\n'

rm -f .pmp-install.lock
rm -rf modules pike.lock

output="$($PMP install 2>&1)"
exit_code=$?

assert "install succeeds" "0" "$exit_code"
assert_not_exists "project lock cleaned up" .pmp-install.lock

# ── Test 3: Store lock cleaned up after normal install ───────────
printf '\n=== Concurrency: store lock cleaned up after install ===\n'

store_lock="$HOME/.pike/store/.lock"
# Pre-remove any leftover store lock from prior tests.
rm -f "$store_lock"

# Re-run install; it acquires and should release the store lock.
rm -rf modules pike.lock

output="$($PMP install 2>&1)"
exit_code=$?

assert "install succeeds for store lock test" "0" "$exit_code"
assert_not_exists "store lock cleaned up" "$store_lock"

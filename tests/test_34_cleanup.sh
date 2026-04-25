# test_34_cleanup.sh -- verify cleanup on die and shared state

# ── Test 1: Project lock released on install error ─────────────────
printf '\n=== Cleanup: project lock released on error ===\n'
TESTDIR="$(mktemp -d)"
track_tempdir "$TESTDIR"
cd "$TESTDIR"

# Create a pike.json with an invalid source that will cause die()
printf '{"name":"cleanup-test","dependencies":{"bad":"https://127.0.0.1:1/impossible/repo"}}' > pike.json
mkdir modules

# Install will fail, but lock should be cleaned up
_out="$("$PMP" install 2>&1 || true)"
_lock_exists=0
[ -f ".pmp-install.lock" ] && _lock_exists=1
assert "project lock cleaned up on error" "0" "$_lock_exists"

# ── Test 2: Store lock released on install error ──────────────────
printf '\n=== Cleanup: store lock released on error ===\n'

_store_lock="$HOME/.pike/store/.lock"
rm -f "$_store_lock"

rm -rf modules pike.lock
_out="$("$PMP" install 2>&1 || true)"
_store_exists=0
[ -f "$_store_lock" ] && _store_exists=1
assert "store lock cleaned up on error" "0" "$_store_exists"

# ── Test 3: Project lock released on remove error ─────────────────
printf '\n=== Cleanup: project lock released on remove error ===\n'

# Create a valid project first
rm -rf modules pike.lock .pmp-install.lock
printf '{"name":"cleanup-rm-test","dependencies":{}}' > pike.json
mkdir modules

# Try to remove a non-existent module (should error but clean up lock)
_out="$("$PMP" remove nonexistent-module 2>&1 || true)"
_lock_exists=0
[ -f ".pmp-install.lock" ] && _lock_exists=1
assert "lock cleaned up on remove error" "0" "$_lock_exists"

# ── Test 4: Temp dirs cleaned up on die ───────────────────────────
printf '\n=== Cleanup: temp dirs cleaned up ===\n'

# Verify no leftover .tmp files in store after failed install
rm -rf modules pike.lock
_tmp_count=$(find "$HOME/.pike/store" -name "*.tmp.*" 2>/dev/null | wc -l)
assert "no leftover temp files in store" "0" "$_tmp_count"

cd /
rm -rf "$TESTDIR"

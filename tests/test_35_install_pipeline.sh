# test_35_install_pipeline.sh — Full install pipeline end-to-end

# Isolate store to avoid interference from global entries
backup_store
# backup_store copies but doesn't remove the original — clean it ourselves
# so verify doesn't flag stale entries from other projects
rm -rf "${HOME:-/tmp}/.pike/store"

# ── Phase 1: Create local git repo fixture ───────────────────────

printf '\n=== Install pipeline: create git fixture ===\n'

TESTDIR="$(mktemp -d)"
cd "$TESTDIR"

# Build a minimal package repo inside the project tree so local deps work
mkdir -p vendor/my-pkg
cd vendor/my-pkg
git init
git config user.email "test@test.com"
git config user.name "Test"

cat > pike.json << 'JSON'
{"name": "my-pkg", "version": "1.0.0"}
JSON

cat > module.pmod << 'PIKE'
// my-pkg module
constant greeting = "hello";
PIKE

git add .
git commit -m 'initial'
git tag v1.0.0

# ── Phase 2: Create pmp project and install ─────────────────────

printf '\n=== Install pipeline: install local dep ===\n'

cd "$TESTDIR"

"$PMP" init

# Overwrite pike.json to add local dep
cat > pike.json << 'JSON'
{"name": "test-project", "version": "0.1.0", "dependencies": {"my-pkg": "./vendor/my-pkg"}}
JSON

_out="$("$PMP" install 2>&1)"
_rc=$?
assert "install exits 0" "0" "$_rc"
assert_output_contains "install reports done" "done" "$_out"

# ── Phase 3: Verify symlink in modules/ ─────────────────────────
# When module.pmod exists at the package root, pmp creates a .pmod symlink

printf '\n=== Install pipeline: verify symlink ===\n'

assert_exists "modules dir created" "modules"
assert_exists "module .pmod symlink exists" "modules/my-pkg.pmod"
assert_exists "module.pmod reachable via symlink" "modules/my-pkg.pmod/module.pmod"

# Verify it is actually a symlink
_link_target="$(ls -l modules/my-pkg.pmod 2>&1)"
case "$_link_target" in
    *"->"*) _is_link="yes" ;;
    *) _is_link="no" ;;
esac
assert "my-pkg.pmod is a symlink" "yes" "$_is_link"

# Verify symlink target points to the fixture
assert_output_contains "symlink points to fixture" "vendor/my-pkg" "$_link_target"

# Verify content is correct
_content="$(cat modules/my-pkg.pmod/module.pmod)"
assert_output_contains "module content is correct" "greeting" "$_content"

# ── Phase 4: Verify lockfile ────────────────────────────────────

printf '\n=== Install pipeline: verify lockfile ===\n'

assert_exists "lockfile created" "pike.lock"
_lock_content="$(cat pike.lock)"
assert_output_contains "lockfile has header" "pmp lockfile v1" "$_lock_content"
assert_output_contains "lockfile has my-pkg" "my-pkg" "$_lock_content"

# Verify lockfile fields (tab-separated: name, source, tag, sha, hash)
_first_data_line="$(sed '/^#/d' pike.lock | head -1)"
_name_field="$(printf '%s' "$_first_data_line" | cut -f1)"
_src_field="$(printf '%s' "$_first_data_line" | cut -f2)"
assert "lockfile name field" "my-pkg" "$_name_field"
assert "lockfile source field" "./vendor/my-pkg" "$_src_field"

# ── Phase 5: Verify store — local deps should NOT create store entries ──

printf '\n=== Install pipeline: verify store (local deps) ===\n'

# Local deps are symlinked directly, not copied to the store.
# The store should not exist (or be empty) for a pure local dep project.
if [ -d "$HOME/.pike/store" ]; then
    _store_count="$(ls "$HOME/.pike/store" 2>/dev/null | wc -l | tr -d ' ')"
    assert "no store entries for local deps" "0" "$_store_count"
else
    # No store dir is fine for local-only deps
    assert "no store dir for local-only project" "yes" "yes"
fi

# ── Phase 6: pmp verify passes ──────────────────────────────────

printf '\n=== Install pipeline: pmp verify ===\n'

_out="$("$PMP" verify 2>&1)"
_rc=$?
assert "verify exits 0" "0" "$_rc"
assert_output_contains "verify all checks passed" "all checks passed" "$_out"

# ── Phase 7: Idempotent install (no re-download) ────────────────

printf '\n=== Install pipeline: idempotent install ===\n'

# Capture lockfile before second install
_lock_before="$(cat pike.lock)"

# Second install should succeed and be a no-op
_out2="$("$PMP" install 2>&1)"
_rc2=$?
assert "second install exits 0" "0" "$_rc2"
assert_output_contains "second install reports done" "done" "$_out2"

# Lockfile should be identical
_lock_after="$(cat pike.lock)"
assert "lockfile unchanged after second install" "$_lock_before" "$_lock_after"

# Symlink still works
assert_exists "symlink still exists after second install" "modules/my-pkg.pmod"
assert_exists "content still correct after second install" "modules/my-pkg.pmod/module.pmod"

# ── Phase 8: Lockfile-based reinstall (remove modules, reinstall) ──

printf '\n=== Install pipeline: reinstall from lockfile ===\n'

rm -rf modules
assert_not_exists "modules removed" "modules"

"$PMP" install 2>&1
assert_exists "modules restored from lockfile" "modules/my-pkg.pmod"
assert_exists "content correct after lockfile reinstall" "modules/my-pkg.pmod/module.pmod"

_out3="$("$PMP" verify 2>&1)"
_rc3=$?
assert "verify passes after lockfile reinstall" "0" "$_rc3"
assert_output_contains "verify ok after lockfile reinstall" "all checks passed" "$_out3"

# ── Cleanup ─────────────────────────────────────────────────────
cd /

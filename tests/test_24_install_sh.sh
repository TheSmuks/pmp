# test_install_sh.sh — install.sh tests

# Derive repo root from PMP shim location
_REPO_ROOT="$(cd "$(dirname "$PMP")/.." && pwd)"

printf '\n=== install.sh: clean install ===\n'
_installdir="$TESTDIR/pmp-install-test"
PMP_INSTALL_DIR="$_installdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1
assert_exists "bin/pmp installed" "$_installdir/bin/pmp"
assert "bin/pmp is executable" "" "$([ -x "$_installdir/bin/pmp" ] && echo '' || echo 'not executable')"

printf '\n=== install.sh: idempotent re-run ===\n'
PMP_INSTALL_DIR="$_installdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1
assert_exists "bin/pmp still exists" "$_installdir/bin/pmp"

printf '\n=== install.sh: non-git dir error ===\n'
_nongitdir="$TESTDIR/pmp-nongit"
mkdir -p "$_nongitdir"
_out="$(PMP_INSTALL_DIR="$_nongitdir" PMP_NO_MODIFY_PATH=1 sh "$_REPO_ROOT/install.sh" 2>&1 || true)"
assert_output_contains "non-git dir error message" "not a git repository" "$_out"

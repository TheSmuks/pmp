# test_changelog.sh — Changelog command tests

printf '\n=== Changelog: no args fails ===\n'
_cl_err="$($PMP changelog 2>&1 || true)"
case "$_cl_err" in *"usage"*) _clna=1 ;; *) _clna=0 ;; esac
assert "changelog no args" "1" "$_clna"

printf '\n=== Changelog: missing module fails ===\n'
# Restore a lockfile for this test
$PMP install
_cl_err2="$($PMP changelog nonexistent 2>&1 || true)"
case "$_cl_err2" in *"not found"*) _clnf=1 ;; *) _clnf=0 ;; esac
assert "changelog missing module" "1" "$_clnf"

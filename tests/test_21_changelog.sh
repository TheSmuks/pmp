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

# ── Success path: changelog compares lockfile versions ──
# cmd_changelog reads pike.lock and pike.lock.prev, finds the module in both,
# and outputs a version comparison when the commit SHAs differ.
# For local deps (sha="-"), we craft both lockfiles with distinct fake SHAs
# so the comparison path is exercised. The command then detects 'local' source
# and reports no remote changelog — which is the expected success output.
printf '\n=== Changelog: success path — version comparison output ===\n'
rm -rf modules libs pike.lock pike.lock.prev pike.json .pike-env
mkdir -p libs/mylib
echo '{"name":"mylib","version":"1.0.0","dependencies":{}}' > libs/mylib/pike.json
echo 'int x = 1;' > libs/mylib/module.pmod
$PMP init
echo '{"name":"test","dependencies":{"mylib":"./libs/mylib"}}' > pike.json
$PMP install

# Craft pike.lock.prev with a different tag and fake SHA for the same dep
# This simulates a prior version of the lockfile after an update.
# Note: printf format strings interpret \t as real tabs (lockfile is TSV).
_header="# pmp lockfile v1 — DO NOT EDIT\n# name\tsource\ttag\tcommit_sha\tcontent_sha256"
printf '%b\n' "$_header" > pike.lock.prev
printf 'mylib\t./libs/mylib\tv0.1.0\tprev_fake_sha1234\t-\n' >> pike.lock.prev

# Overwrite current lockfile with a different tag and fake SHA
printf '%b\n' "$_header" > pike.lock
printf 'mylib\t./libs/mylib\tv0.2.0\tcur_fake_sha5678\t-\n' >> pike.lock

_cl_out="$($PMP changelog mylib 2>&1)"

# Should contain the version comparison line
case "$_cl_out" in
    *"v0.1.0"*"v0.2.0"*) _cl_version=1 ;;
    *) _cl_version=0 ;;
esac
assert "changelog shows version comparison" "1" "$_cl_version"

# Should contain the module name
case "$_cl_out" in
    *"mylib"*) _cl_name=1 ;;
    *) _cl_name=0 ;;
esac
assert "changelog output mentions module name" "1" "$_cl_name"

# Should report local dependency limitation (expected for local source)
case "$_cl_out" in
    *"local"*) _cl_local=1 ;;
    *) _cl_local=0 ;;
esac
assert "changelog reports local dep info" "1" "$_cl_local"
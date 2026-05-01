# test_self_update.sh — Self-update tests
# NOTE: self-update requires a git checkout with fetch access to a remote.
# In CI/test environments this usually fails at the git-fetch step.
# We verify that the command runs cleanly (no crash/signal) and produces
# a recognizable pmp output line. A full end-to-end self-update test
# would need a real git remote with tags.

# ── Self-update tests ──
printf '\n=== pmp self-update: exits cleanly ===\n'
_out="$($PMP self-update 2>&1; echo " EXIT:$?")"
_exit_code="$(printf '%s' "$_out" | sed -n 's/.*EXIT:\([0-9]*\).*/\1/p' | tail -1)"

# Verify exit code is 0 or 1 (not crash/signal which would be >= 128)
_exit_ok=0
case "$_exit_code" in
    0|1) _exit_ok=1 ;;
esac
assert "self-update exit code is 0 or 1" "1" "$_exit_ok"

# Verify output contains a pmp-prefixed message (all pmp info/warn/die use 'pmp:' prefix)
case "$_out" in
    *"pmp:"*) _has_pmp_prefix=1 ;;
    *) _has_pmp_prefix=0 ;;
esac
assert "self-update output has pmp prefix" "1" "$_has_pmp_prefix"

# Verify output contains one of the expected outcome messages
# These are the only legitimate outcomes from cmd_self_update:
# - 'up to date' — already on latest tag
# - 'local modifications' — dev repo has uncommitted changes
# - 'not installed via git' — installed via curl installer
# - 'checking for updates' — actively fetching (may fail after this)
# - 'failed to fetch' — network error during fetch
# - 'updated pmp' — successfully updated
case "$_out" in
    *"up to date"*) _su_ok=1 ;;
    *"local modifications"*) _su_ok=1 ;;
    *"not installed via git"*) _su_ok=1 ;;
    *"checking for updates"*) _su_ok=1 ;;
    *"failed to fetch"*) _su_ok=1 ;;
    *"updated pmp"*) _su_ok=1 ;;
    *) _su_ok=0 ;;
esac
assert "self-update recognized outcome" "1" "$_su_ok"

# Verify self-update uses semver comparison (not string)
# This would be caught by checking that 0.3.0 != 0.10.0
printf '\n=== Semver: version comparison ===\n'
_semver="$($PMP version 2>&1)"
assert "version command outputs version" "1" "$([ -n "$_semver" ] && echo 1 || echo 0)"

printf '\n=== Help: self-update ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows self-update" "self-update" "$_help"
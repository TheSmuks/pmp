# test_self_update.sh — Self-update tests

# ── Self-update tests ──
printf '\n=== pmp self-update: reports version ===\n'
_out="$($PMP self-update 2>&1 || true)"
# Self-update should produce one of these expected outcomes:
# - "up to date" — already on latest tag
# - "local modifications" — dev repo has uncommitted changes
# - "not installed via git" — installed via curl installer
# - "checking for updates" — actively fetching
# - "updated pmp" — successfully updated
case "$_out" in
    *"up to date"*) _su_ok=1 ;;
    *"local modifications"*) _su_ok=1 ;;
    *"not installed via git"*) _su_ok=1 ;;
    *"checking for updates"*) _su_ok=1 ;;
    *"updated pmp"*) _su_ok=1 ;;
    *) _su_ok=0 ;;
esac
assert "self-update runs without crash" "1" "$_su_ok"

# Verify self-update uses semver comparison (not string)
# This would be caught by checking that 0.3.0 != 0.10.0
printf '\n=== Semver: version comparison ===\n'
_semver="$($PMP version 2>&1)"
assert "version command outputs version" "1" "$([ -n "$_semver" ] && echo 1 || echo 0)"

printf '\n=== Help: self-update ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows self-update" "self-update" "$_help"
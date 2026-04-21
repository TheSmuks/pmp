# test_self_update.sh — Self-update tests

# ── Self-update tests ──
printf '\n=== pmp self-update: reports version ===\n'
_out="$($PMP self-update 2>&1 || true)"
# In the dev repo, we likely have local modifications, so it may abort
# Either "up to date" or "local modifications" is acceptable
case "$_out" in
    *"up to date"*) _su_ok=1 ;;
    *"local modifications"*) _su_ok=1 ;;
    *"not installed via git"*) _su_ok=1 ;;
    *"checking for updates"*) _su_ok=1 ;;
    *) _su_ok=0 ;;
esac
assert "self-update runs without crash" "1" "$_su_ok"

printf '\n=== Help: self-update ===\n'
_help="$($PMP --help 2>&1)"
assert_output_contains "help shows self-update" "self-update" "$_help"

# test_activate.sh — Activate/deactivate

printf '\n=== Activate/deactivate ===\n'
# Source activate and verify PATH
_eval="$(. ./.pike-env/activate 2>/dev/null; which pike 2>&1)"
assert_output_contains "activated pike is env wrapper" ".pike-env/bin/pike" "$_eval"

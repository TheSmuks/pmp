# test_version.sh — pmp version command

printf '\n=== pmp version ===\n'
_out="$($PMP version)"
case "$_out" in *"pmp v"*) _vok=1 ;; *) _vok=0 ;; esac
assert "version output" "1" "$_vok"

# test_error_paths.sh — Error path tests

printf '\n=== Error paths ===\n'

# pmp --version (flag path via Arg.parse)
_out="$($PMP --version 2>&1)"
case "$_out" in *"pmp v"*) _vf=1 ;; *) _vf=0 ;; esac
assert "--version flag" "1" "$_vf"

# pmp foobar → unknown command exit
_out="$($PMP foobar 2>&1 || true)"
case "$_out" in *"unknown command"*) _uc=1 ;; *) _uc=0 ;; esac
assert "unknown command" "1" "$_uc"

# pmp remove (no args) → usage error
_out="$($PMP remove 2>&1 || true)"
case "$_out" in *"usage"*) _ru=1 ;; *) _ru=0 ;; esac
assert "remove no args" "1" "$_ru"

# pmp run (no args) → usage error
_out="$($PMP run 2>&1 || true)"
case "$_out" in *"usage"*) _rn=1 ;; *) _rn=0 ;; esac
assert "run no args" "1" "$_rn"

# pmp install without pike.json → die
rm -f pike.json
_out="$($PMP install 2>&1 || true)"
case "$_out" in *"pike.json"*) _npj=1 ;; *) _npj=0 ;; esac
assert "install without pike.json" "1" "$_npj"

rm -rf modules libs pike.lock

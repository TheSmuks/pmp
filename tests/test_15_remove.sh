# test_remove.sh — pmp remove command

rm -rf modules libs
printf '\n=== pmp remove ===\n'
cat > pike.json << 'JSON'
{
  "dependencies": {
    "local-mod": "./libs/local-mod",
    "other-mod": "./libs/other-mod"
  }
}
JSON
mkdir -p libs/local-mod libs/other-mod
echo '# test' > libs/local-mod/test.pike
echo '# test' > libs/other-mod/test.pike
"$PMP" install
assert_exists "local-mod installed" "modules/local-mod"
assert_exists "other-mod installed" "modules/other-mod"
"$PMP" remove local-mod
assert_not_exists "local-mod removed from modules" "modules/local-mod"
assert_exists "other-mod still installed" "modules/other-mod"
# Verify pike.json was updated
assert_output_contains "pike.json updated" "other-mod" "$(cat pike.json)"
_out="$(cat pike.json)"
case "$_out" in *local-mod*) _has_lm=1 ;; *) _has_lm=0 ;; esac
assert "local-mod removed from pike.json" "0" "$_has_lm"

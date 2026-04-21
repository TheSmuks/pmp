# test_run.sh — pmp run command

printf '\n=== pmp run ===\n'
cat > test_script.pike << 'PIKE'
int main() { write("hello from pike\n"); return 0; }
PIKE
_out="$("$PMP" run test_script.pike 2>&1)"
assert "pmp run executes script" "hello from pike" "$_out"
rm -f test_script.pike

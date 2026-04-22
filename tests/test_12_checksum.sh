# test_checksum.sh — SHA256 checksum

printf '\n=== Checksum: compute_sha256 ===\n'
echo "test content" > "$TESTDIR/pmp-test-sha.txt"
_hash="$(sha256sum "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"
[ -z "$_hash" ] && _hash="$(shasum -a 256 "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"
assert "sha256 computes" "" "$([ -n "$_hash" ] && echo '' || echo 'no hash tool')"

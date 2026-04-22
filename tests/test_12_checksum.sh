# test_checksum.sh — SHA256 checksum and content hash

printf '\n=== Checksum: compute_sha256 ===\n'
echo "test content" > "$TESTDIR/pmp-test-sha.txt"

# Compute expected hash using system sha256sum
_expected="$(sha256sum "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"
[ -z "$_expected" ] && _expected="$(shasum -a 256 "$TESTDIR/pmp-test-sha.txt" 2>/dev/null | cut -d ' ' -f1)"

if [ -n "$_expected" ]; then
    # Verify Pike's compute_sha256 matches system sha256sum
    _pike_hash="$(pike -M "$_PMP_DIR" -e "import Pmp; write(compute_sha256(\"$TESTDIR/pmp-test-sha.txt\"));" 2>/dev/null)"
    assert "pike compute_sha256 matches sha256sum" "$_expected" "$_pike_hash"
else
    # No system hash tool — just verify Pike produces a 64-char hex string
    _pike_hash="$(pike -M "$_PMP_DIR" -e "import Pmp; write(compute_sha256(\"$TESTDIR/pmp-test-sha.txt\"));" 2>/dev/null)"
    assert "pike compute_sha256 produces hash" "1" "$([ ${#_pike_hash} -eq 64 ] && echo 1 || echo 0)"
fi

printf '\n=== Checksum: compute_dir_hash uses Pike walk ===\n'
mkdir -p "$TESTDIR/dir-test/sub"
echo "aaa" > "$TESTDIR/dir-test/a.txt"
echo "bbb" > "$TESTDIR/dir-test/sub/b.txt"
_dir_hash="$(pike -M "$_PMP_DIR" -e "import Pmp; write(compute_dir_hash(\"$TESTDIR/dir-test\"));" 2>/dev/null)"
assert "compute_dir_hash produces 64-char hex" "64" "${#_dir_hash}"
# Verify determinism — same content, same hash
_dir_hash2="$(pike -M "$_PMP_DIR" -e "import Pmp; write(compute_dir_hash(\"$TESTDIR/dir-test\"));" 2>/dev/null)"
assert "compute_dir_hash is deterministic" "$_dir_hash" "$_dir_hash2"
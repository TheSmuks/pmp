# test_30_adversarial.sh — Adversarial / edge-case tests

printf '\n=== Adversarial Tests ===\n'

TESTDIR="$(mktemp -d)"
cd "$TESTDIR"

# ── pmp init with special directory names ──────────────────────────

# Double-quote in directory name
_adir="$(mktemp -d)/test\"inject"
mkdir -p "$_adir"
cd "$_adir"
"$PMP" init 2>&1
assert_exists "init with double-quote dir: pike.json created" "pike.json"
_err1="$(pike -e 'mixed e=catch{Standards.JSON.decode(Stdio.read_file("pike.json"));};if(e) werror("BAD JSON\n");' 2>&1 || true)"
case "$_err1" in *"BAD JSON"*) _jq1=0 ;; *) _jq1=1 ;; esac
assert "init with double-quote dir: pike.json is valid JSON" "1" "$_jq1"
cd "$TESTDIR"
rm -rf "$_adir"

# Unicode in directory name
_udir="$(mktemp -d)/test-αβγ"
mkdir -p "$_udir"
cd "$_udir"
"$PMP" init 2>&1
assert_exists "init with unicode dir: pike.json created" "pike.json"
_err2="$(pike -e 'mixed e=catch{Standards.JSON.decode(Stdio.read_file("pike.json"));};if(e) werror("BAD JSON\n");' 2>&1 || true)"
case "$_err2" in *"BAD JSON"*) _jq2=0 ;; *) _jq2=1 ;; esac
assert "init with unicode dir: pike.json is valid JSON" "1" "$_jq2"
cd "$TESTDIR"
rm -rf "$_udir"

# Space in directory name
_sdir="$(mktemp -d)/test name"
mkdir -p "$_sdir"
cd "$_sdir"
"$PMP" init 2>&1
assert_exists "init with space dir: pike.json created" "pike.json"
_err3="$(pike -e 'mixed e=catch{Standards.JSON.decode(Stdio.read_file("pike.json"));};if(e) werror("BAD JSON\n");' 2>&1 || true)"
case "$_err3" in *"BAD JSON"*) _jq3=0 ;; *) _jq3=1 ;; esac
assert "init with space dir: pike.json is valid JSON" "1" "$_jq3"
cd "$TESTDIR"
rm -rf "$_sdir"

# ── pmp install with malformed pike.json ───────────────────────────

printf '{"name":' > pike.json
_out_mal="$("$PMP" install 2>&1 || true)"
# parse_deps silently returns empty on malformed JSON — verify no crash/trace
case "$_out_mal" in
  *"Trace"*|*"backtrace"*) _mal_crash=1 ;;
  *) _mal_crash=0 ;;
esac
assert "malformed JSON does not crash install" "0" "$_mal_crash"

# ── pmp install with null dependencies ─────────────────────────────

printf '{"dependencies": null}' > pike.json
_out_null="$("$PMP" install 2>&1 || true)"
case "$_out_null" in
  *"Trace"*|*"backtrace"*) _crash=1 ;;
  *) _crash=0 ;;
esac
assert "null dependencies does not crash" "0" "$_crash"

# ── pmp remove with path traversal ─────────────────────────────────

printf '{"name":"adv-test","dependencies":{}}' > pike.json
mkdir -p modules

_out_pt1="$("$PMP" remove '..' 2>&1 || true)"
assert_output_contains "path traversal '..' rejected" "invalid module name" "$_out_pt1"

_out_pt2="$("$PMP" remove '../etc' 2>&1 || true)"
assert_output_contains "path traversal '../etc' rejected" "invalid module name" "$_out_pt2"

# ── pmp remove nonexistent module ──────────────────────────────────

_out_ne="$("$PMP" remove nonexistent 2>&1 || true)"
assert_output_contains "remove nonexistent reports error" "not found" "$_out_ne"

# ── Lockfile parsing: header-only lockfile ──────────────────────────

rm -f pike.lock
printf '# pmp lockfile v1 — DO NOT EDIT\n# name\tsource\ttag\tcommit_sha\tcontent_sha256\n' > pike.lock
_out_lf="$("$PMP" install 2>&1 || true)"
# Should handle gracefully — no crash
case "$_out_lf" in
  *"Trace"*|*"backtrace"*) _lf_crash=1 ;;
  *) _lf_crash=0 ;;
esac
assert "header-only lockfile does not crash" "0" "$_lf_crash"

# ── validate_version_tag via install ───────────────────────────────

# Use a valid 3-part source (domain/owner/repo) with traversal tag
_out_vt="$("$PMP" install 'github.com/owner/repo#v1.0..0' 2>&1 || true)"
assert_output_contains "version tag path traversal rejected" "path traversal" "$_out_vt"

# ── Cleanup ────────────────────────────────────────────────────────
rm -rf modules libs pike.lock
rm -f "${HOME}/.pike/store/.lock"
cd /
rm -rf "$TESTDIR"

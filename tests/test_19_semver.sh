# test_semver.sh — Semver parsing and comparison tests

# Derive module path from the PMP shim location
_PMP_DIR="$(dirname "$PMP")"
# Module path: all modules now under Pmp.pmod/
_SEMVER_M="$_PMP_DIR"

printf '\n=== Semver: parse and compare ===\n'
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
_out="$(PIKE_MODULE_PATH="$_SEMVER_M" pike -e '
import Pmp.Semver;
mapping v = parse_semver("v1.2.3");
write("%d.%d.%d\n", v["major"], v["minor"], v["patch"]);
write("cmp: %d\n", compare_semver(parse_semver("1.0.0"), parse_semver("2.0.0")));
write("sorted: %s\n", sort_tags_semver(({"v0.1.0", "v2.0.0", "v1.5.0"})) * ", ");
write("bump: %s\n", classify_bump("v1.0.0", "v2.0.0"));
')"
assert_output_contains "parse major" "1" "$_out"
assert_output_contains "parse minor" "2" "$_out"
assert_output_contains "parse patch" "3" "$_out"
assert_output_contains "compare 1<2" "cmp: -1" "$_out"
assert_output_contains "sort highest first" "v2.0.0" "$_out"
assert_output_contains "classify major" "bump: major" "$_out"

printf '\n=== Semver: non-semver tags sort last ===\n'
_out="$(PIKE_MODULE_PATH="$_SEMVER_M" pike -e '
import Pmp.Semver;
write("%s\n", sort_tags_semver(({"latest", "v1.0.0", "v0.5.0", "nightly"})) * ", ");
')"
# v1.0.0 should be first (highest semver), non-semver last
case "$_out" in *"v1.0.0"*) _nsv=1 ;; *) _nsv=0 ;; esac
assert "semver before non-semver" "1" "$_nsv"

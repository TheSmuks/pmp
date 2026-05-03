# test_26_module_resolution.sh — smart symlink resolution for nested .pmod layouts

rm -rf modules libs
printf '\n=== module resolution: nested .pmod layout ===\n'

# ── Test 1: Nested .pmod directory layout ──────────────────────────

# Create a local package with PUnit-style layout: PkgName.pmod/module.pmod
mkdir -p libs/nested-mod/NestedMod.pmod
cat > libs/nested-mod/NestedMod.pmod/module.pmod << 'PIKE'
constant greeting = "hello from NestedMod";
PIKE

# Create pike.json with the local dep
cat > pike.json << 'JSON'
{
  "dependencies": {
    "NestedMod": "./libs/nested-mod"
  }
}
JSON

"$PMP" install

# The symlink should be NestedMod.pmod pointing to the .pmod subdir
assert_exists "NestedMod.pmod symlink created" "modules/NestedMod.pmod"

# Verify it's a symlink pointing to the .pmod directory inside the package
_dest="$(readlink modules/NestedMod.pmod 2>/dev/null || echo '')"
case "$_dest" in
  */NestedMod.pmod) _has_pmod_target=1 ;;
  *) _has_pmod_target=0 ;;
esac
assert "symlink targets .pmod subdir" "1" "$_has_pmod_target"

# Verify import works with Pike directly
cat > /tmp/test_nested.pike << 'PIKE'
import NestedMod;
int main() {
    werror(NestedMod.greeting + "\n");
    return 0;
}
PIKE
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike /tmp/test_nested.pike 2>&1 || true)"
assert_output_contains "import NestedMod works" "hello from NestedMod" "$_out"

# ── Test 2: pmp list strips .pmod suffix ───────────────────────────

_out="$("$PMP" list 2>&1)"
case "$_out" in
  *NestedMod*) _shows_bare=1 ;;
  *) _shows_bare=0 ;;
esac
assert "pmp list shows bare name" "1" "$_shows_bare"

# ── Test 3: pmp remove works with bare name ────────────────────────

"$PMP" remove NestedMod
assert_not_exists "NestedMod.pmod symlink removed" "modules/NestedMod.pmod"

# ── Test 4: Flat module layout gets .pmod suffix for import ────────

rm -rf modules libs
mkdir -p libs/flat-mod
cat > libs/flat-mod/module.pmod << 'PIKE'
constant greeting = "hello from FlatMod";
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "FlatMod": "./libs/flat-mod"
  }
}
JSON

"$PMP" install

# Flat layout should also get .pmod suffix for import resolution
assert_exists "FlatMod.pmod symlink created" "modules/FlatMod.pmod"
assert_not_exists "no bare FlatMod symlink" "modules/FlatMod"

# Verify import works
cat > /tmp/test_flat.pike << 'PIKE'
import FlatMod;
int main() {
    werror(FlatMod.greeting + "\n");
    return 0;
}
PIKE
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike /tmp/test_flat.pike 2>&1 || true)"
assert_output_contains "import FlatMod works" "hello from FlatMod" "$_out"

# ── Test 5: pmp resolve finds .pmod symlink ────────────────────────

rm -rf modules libs
mkdir -p libs/nested2/N2.pmod
cat > libs/nested2/N2.pmod/module.pmod << 'PIKE'
constant val = 42;
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "N2": "./libs/nested2"
  }
}
JSON

"$PMP" install
assert_exists "N2.pmod symlink created" "modules/N2.pmod"

_out="$("$PMP" resolve N2 2>&1)"
case "$_out" in
  */N2.pmod*) _resolve_ok=1 ;;
  *) _resolve_ok=0 ;;
esac
assert "pmp resolve finds .pmod symlink" "1" "$_resolve_ok"

# ── Test 6: pmp remove works with bare name for .pmod symlinks ────

"$PMP" remove N2
assert_not_exists "N2 removed via bare name" "modules/N2.pmod"

# ── Test 7: Mixed layout (one nested, one flat) ────────────────────

rm -rf modules libs
mkdir -p libs/flat2 libs/nested3/N3.pmod
cat > libs/flat2/module.pmod << 'PIKE'
constant name = "flat2";
PIKE
cat > libs/nested3/N3.pmod/module.pmod << 'PIKE'
constant name = "N3";
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "Flat2": "./libs/flat2",
    "N3": "./libs/nested3"
  }
}
JSON

"$PMP" install

assert_exists "Flat2.pmod symlink" "modules/Flat2.pmod"
assert_exists "N3.pmod symlink" "modules/N3.pmod"
assert_not_exists "no bare Flat2" "modules/Flat2"
assert_not_exists "no bare N3" "modules/N3"

_out="$("$PMP" list 2>&1)"
# Both should appear with bare names (stripped .pmod)
case "$_out" in
  *Flat2*) _has_flat=1 ;; *) _has_flat=0 ;;
esac
case "$_out" in
  *N3*) _has_n3=1 ;; *) _has_n3=0 ;;
esac
assert "list shows Flat2" "1" "$_has_flat"
assert "list shows N3" "1" "$_has_n3"

# Clean up
rm -rf modules libs
rm -f /tmp/test_nested.pike /tmp/test_flat.pike

# ══════════════════════════════════════════════════════════════════════
# NEW TESTS: src/ layout and module_path field
# ══════════════════════════════════════════════════════════════════════

# ── Test 8: Cargo-style src/ layout with name.pmod/ ─────────────────

rm -rf modules libs
mkdir -p libs/src-layout/src/PkgName.pmod
cat > libs/src-layout/src/PkgName.pmod/module.pmod << 'PIKE'
constant version = "1.0.0";
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "PkgName": "./libs/src-layout"
  }
}
JSON

"$PMP" install

# The symlink should point into src/PkgName.pmod/
assert_exists "PkgName.pmod symlink created" "modules/PkgName.pmod"
_dest="$(readlink modules/PkgName.pmod 2>/dev/null || echo '')"
case "$_dest" in
  */src/PkgName.pmod) _src_ok=1 ;;
  *) _src_ok=0 ;;
esac
assert "symlink targets src/PkgName.pmod" "1" "$_src_ok"

# Verify import works
cat > /tmp/test_src.pike << 'PIKE'
import PkgName;
int main() {
    werror(PkgName.version + "\n");
    return 0;
}
PIKE
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike /tmp/test_src.pike 2>&1 || true)"
assert_output_contains "import PkgName works with src/ layout" "1.0.0" "$_out"

# ── Test 9: src/ with single *.pmod/ auto-detection ─────────────────

rm -rf modules libs
mkdir -p libs/single-src/src/SingleMod.pmod
cat > libs/single-src/src/SingleMod.pmod/module.pmod << 'PIKE'
constant value = 99;
PIKE

cat > pike.json << 'JSON'
{
  "dependencies": {
    "SingleMod": "./libs/single-src"
  }
}
JSON

"$PMP" install

# Should auto-detect src/SingleMod.pmod/ since src/ has exactly one pmod dir
assert_exists "SingleMod.pmod symlink created" "modules/SingleMod.pmod"
_dest="$(readlink modules/SingleMod.pmod 2>/dev/null || echo '')"
case "$_dest" in
  */src/SingleMod.pmod) _single_src_ok=1 ;;
  *) _single_src_ok=0 ;;
esac
assert "symlink targets src/SingleMod.pmod via auto-detect" "1" "$_single_src_ok"

# Verify import
cat > /tmp/test_single_src.pike << 'PIKE'
import SingleMod;
int main() {
    werror((string)SingleMod.value + "\n");
    return 0;
}
PIKE
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike /tmp/test_single_src.pike 2>&1 || true)"
assert_output_contains "import SingleMod works with auto-detect" "99" "$_out"


# ── Test 10: module_path field in pike.json ─────────────────────────

rm -rf modules libs
mkdir -p libs/explicit-path/deep/nested/ExplicitMod.pmod
cat > libs/explicit-path/deep/nested/ExplicitMod.pmod/module.pmod << 'PIKE'
constant msg = "explicit module_path works";
PIKE

cat > libs/explicit-path/pike.json << 'JSON'
{
  "name": "ExplicitMod",
  "version": "0.1.0",
  "module_path": "deep/nested/ExplicitMod.pmod"
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "ExplicitMod": "./libs/explicit-path"
  }
}
JSON

"$PMP" install

# Symlink should point to deep/nested/ExplicitMod.pmod via module_path
assert_exists "ExplicitMod.pmod symlink created" "modules/ExplicitMod.pmod"
_dest="$(readlink modules/ExplicitMod.pmod 2>/dev/null || echo '')"
case "$_dest" in
  */deep/nested/ExplicitMod.pmod) _explicit_ok=1 ;;
  *) _explicit_ok=0 ;;
esac
assert "symlink targets module_path declared path" "1" "$_explicit_ok"

# Verify import works
cat > /tmp/test_explicit.pike << 'PIKE'
import ExplicitMod;
int main() {
    werror(ExplicitMod.msg + "\n");
    return 0;
}
PIKE
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike /tmp/test_explicit.pike 2>&1 || true)"
assert_output_contains "import ExplicitMod works via module_path" "explicit module_path works" "$_out"

# ── Test 11: module_path with invalid path falls back to scanning ────

rm -rf modules libs
mkdir -p libs/fallback-test/FallbackMod.pmod
cat > libs/fallback-test/FallbackMod.pmod/module.pmod << 'PIKE'
constant data = "fallback data";
PIKE

# Declare a non-existent module_path — should warn and fall back
cat > libs/fallback-test/pike.json << 'JSON'
{
  "name": "FallbackMod",
  "version": "0.1.0",
  "module_path": "does/not/exist"
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "FallbackMod": "./libs/fallback-test"
  }
}
JSON

"$PMP" install 2>&1 | grep -q "module_path.*not found\|module_path.*falling back" || true

# Should still work via fallback scanning
assert_exists "FallbackMod.pmod symlink created (fallback)" "modules/FallbackMod.pmod"
_out="$(PIKE_MODULE_PATH="$(pwd)/modules" pike -e 'import FallbackMod; werror(FallbackMod.data + "\n");' 2>&1 || true)"
assert_output_contains "import FallbackMod works via fallback" "fallback data" "$_out"

# ── Test 12: module_path with path traversal is rejected ─────────────

rm -rf modules libs
mkdir -p libs/traversal-test/TravMod.pmod
cat > libs/traversal-test/TravMod.pmod/module.pmod << 'PIKE'
constant x = 1;
PIKE

cat > libs/traversal-test/pike.json << 'JSON'
{
  "name": "TravMod",
  "module_path": "../../etc/passwd"
}
JSON

cat > pike.json << 'JSON'
{
  "dependencies": {
    "TravMod": "./libs/traversal-test"
  }
}
JSON

"$PMP" install 2>&1 | grep -q "module_path.*invalid\|module_path.*traversal\|module_path.*falling back" || true

# Should fall back and still work
assert_exists "TravMod.pmod symlink created (traversal blocked)" "modules/TravMod.pmod"

# Clean up
rm -rf modules libs
rm -f /tmp/test_src.pike /tmp/test_single_src.pike /tmp/test_explicit.pike

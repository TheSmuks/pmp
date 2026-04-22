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

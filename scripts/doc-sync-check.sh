#!/bin/sh
# doc-sync-check.sh — Verify documentation matches codebase reality.
# Exit 1 on any mismatch. Run in CI to block drift.
set -eu

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

ERRORS=""

# ── 1. PMP_VERSION consistency ────────────────────────────────────
CONFIG_VER=$(sed -n 's/.*PMP_VERSION *= *"\([^"]*\)".*/\1/p' bin/Pmp.pmod/Config.pmod | head -1)
if [ -z "$CONFIG_VER" ]; then
    ERRORS="${ERRORS}ERROR: Cannot extract PMP_VERSION from bin/Pmp.pmod/Config.pmod\n"
fi

# Check ARCHITECTURE.md mentions the correct version
if [ -n "$CONFIG_VER" ]; then
    if ! grep -q "$CONFIG_VER" ARCHITECTURE.md 2>/dev/null; then
        ERRORS="${ERRORS}ERROR: ARCHITECTURE.md does not mention version $CONFIG_VER (from Config.pmod)\n"
    fi
fi

# ── 2. Module count consistency ───────────────────────────────────
MODULE_COUNT=$(ls bin/Pmp.pmod/*.pmod 2>/dev/null | grep -v module.pmod | wc -l)
if [ "$MODULE_COUNT" -eq 0 ]; then
    ERRORS="${ERRORS}ERROR: Cannot count modules in bin/Pmp.pmod/\n"
fi

# ARCHITECTURE.md should mention the correct module count
if ! grep -q "$MODULE_COUNT" ARCHITECTURE.md 2>/dev/null; then
    ERRORS="${ERRORS}ERROR: ARCHITECTURE.md module count does not match module.pmod ($MODULE_COUNT modules)\n"
fi

# ── 3. SHA prefix consistency ─────────────────────────────────────
# Store.pmod uses sha[..15] which is 16 chars
SHA_PREFIX_CODE=$(grep -o 'sha\[\.\.15\]' bin/Pmp.pmod/Store.pmod 2>/dev/null | head -1)
if [ -n "$SHA_PREFIX_CODE" ]; then
    # ARCHITECTURE.md and README should say 16, not 8
    if grep -q 'sha_prefix8\|8 characters\|8-char' ARCHITECTURE.md 2>/dev/null; then
        ERRORS="${ERRORS}ERROR: ARCHITECTURE.md still references 8-char SHA prefix (code uses 16)\n"
    fi
    if grep -q 'sha_prefix8\|8 characters\|8-char' README.md 2>/dev/null; then
        ERRORS="${ERRORS}ERROR: README.md still references 8-char SHA prefix (code uses 16)\n"
    fi
fi

# ── 4. Module directory consistency ────────────────────────────────
if [ ! -d "bin/Pmp.pmod" ]; then
    ERRORS="${ERRORS}ERROR: Expected module directory bin/Pmp.pmod does not exist\n"
fi

# ── 5. Test count in AGENTS.md matches runner ─────────────────────
# We can't run the tests here, but we can check that AGENTS.md
# doesn't claim obviously stale Pike test counts
# Check for known stale test count patterns
if grep -q '317 Pike\|119.*shell' AGENTS.md 2>/dev/null; then
    ERRORS="${ERRORS}ERROR: AGENTS.md references stale test counts\n"
fi

# ── 6. No fabricated features in behavior-spec ────────────────────
if grep -q '60-second TTL\|ETag support\|MAX_TAG_PAGES\|LOCK_MAX_ATTEMPTS\|LOCK_BACKOFF_BASE' docs/behavior-spec.md 2>/dev/null; then
    ERRORS="${ERRORS}ERROR: docs/behavior-spec.md still contains fabricated features (caching/TTL/ETag/non-existent constants)\n"
fi

# ── 7. ADR-0003 should not claim Accepted for unimplemented features
if grep -q 'Status:.*Accepted' docs/decisions/0003-lockfile-v2.md 2>/dev/null; then
    ERRORS="${ERRORS}ERROR: docs/decisions/0003-lockfile-v2.md claims Accepted but lockfile v2 is not implemented\n"
fi

# ── 8. Line count consistency (AGENTS.md vs actual files) ─────────
# Check that claimed line counts are within ±50 lines of actual
# (allowing for approximations in documentation)

check_line_count() {
    ACTUAL_LINES="$1"
    CLAIM="$2"        # raw ~NNN string
    DOC_NAME="$3"

    # Strip leading tilde
    CLAIM_VAL=$(echo "$CLAIM" | sed 's/~//')

    # Calculate absolute difference
    DIFF=$(( ACTUAL_LINES - CLAIM_VAL ))
    if [ "$DIFF" -lt 0 ]; then
        DIFF=$((- DIFF))
    fi

    # Allow ±50 lines tolerance for line count approximations
    if [ "$DIFF" -gt 50 ]; then
        ERRORS="${ERRORS}ERROR: $DOC_NAME claims ~${CLAIM_VAL} but actual is ${ACTUAL_LINES} lines (diff: $DIFF)\n"
    fi
}

# Verify.pmod line count
VERIFY_ACTUAL=$(wc -l < "$REPO_ROOT/bin/Pmp.pmod/Verify.pmod" 2>/dev/null || echo 0)
VERIFY_CLAIM=$(grep 'Verify.pmod' "$REPO_ROOT/AGENTS.md" | grep -o '~[0-9]\+' | head -1)
if [ -n "$VERIFY_CLAIM" ]; then
    check_line_count "$VERIFY_ACTUAL" "$VERIFY_CLAIM" "AGENTS.md (Verify.pmod)"
fi

# Update.pmod line count
UPDATE_ACTUAL=$(wc -l < "$REPO_ROOT/bin/Pmp.pmod/Update.pmod" 2>/dev/null || echo 0)
UPDATE_CLAIM=$(grep 'Update.pmod' "$REPO_ROOT/AGENTS.md" | grep -o '~[0-9]\+' | head -1)
if [ -n "$UPDATE_CLAIM" ]; then
    check_line_count "$UPDATE_ACTUAL" "$UPDATE_CLAIM" "AGENTS.md (Update.pmod)"
fi

# LockOps.pmod line count
LOCKOPS_ACTUAL=$(wc -l < "$REPO_ROOT/bin/Pmp.pmod/LockOps.pmod" 2>/dev/null || echo 0)
LOCKOPS_CLAIM=$(grep 'LockOps.pmod' "$REPO_ROOT/AGENTS.md" | grep -o '~[0-9]\+' | head -1)
if [ -n "$LOCKOPS_CLAIM" ]; then
    check_line_count "$LOCKOPS_ACTUAL" "$LOCKOPS_CLAIM" "AGENTS.md (LockOps.pmod)"
fi

# pmp.pike line count (ARCHITECTURE.md section)
PMPIKE_ACTUAL=$(wc -l < "$REPO_ROOT/bin/pmp.pike" 2>/dev/null || echo 0)
PMPIKE_CLAIM=$(grep 'pmp.pike' "$REPO_ROOT/ARCHITECTURE.md" | grep -o '~[0-9]\+' | head -1)
if [ -n "$PMPIKE_CLAIM" ]; then
    check_line_count "$PMPIKE_ACTUAL" "$PMPIKE_CLAIM" "ARCHITECTURE.md (pmp.pike)"
fi

# Install.pmod line count (ARCHITECTURE.md section)
INSTALL_ACTUAL=$(wc -l < "$REPO_ROOT/bin/Pmp.pmod/Install.pmod" 2>/dev/null || echo 0)
INSTALL_CLAIM=$(grep 'Install\.pmod.*install_one' "$REPO_ROOT/ARCHITECTURE.md" | grep -o '~[0-9]\+' | head -1)
if [ -n "$INSTALL_CLAIM" ]; then
    check_line_count "$INSTALL_ACTUAL" "$INSTALL_CLAIM" "ARCHITECTURE.md (Install.pmod)"
fi

# Total source line count
TOTAL_ACTUAL=$(wc -l "$REPO_ROOT/bin/pmp.pike" "$REPO_ROOT/bin/Pmp.pmod"/*.pmod 2>/dev/null | tail -1 | awk '{print $1}')
# Match "NNN lines total source" pattern specifically
TOTAL_CLAIM=$(grep -o '~[0-9]\+ lines total source' "$REPO_ROOT/AGENTS.md" 2>/dev/null | grep -o '~[0-9]\+' | head -1)
if [ -n "$TOTAL_CLAIM" ]; then
    check_line_count "$TOTAL_ACTUAL" "$TOTAL_CLAIM" "AGENTS.md (total source)"
fi

# ── 9. Shell test count consistency ───────────────────────────────
# AGENTS.md and ARCHITECTURE.md should agree on shell test count
AGENTS_SHELL=$(grep -E '[0-9]{3}' "$REPO_ROOT/AGENTS.md" 2>/dev/null | grep 'shell' | grep -o '[0-9]\{3\}' | head -1)
ARCH_SHELL=$(grep -E '[0-9]{3}' "$REPO_ROOT/ARCHITECTURE.md" 2>/dev/null | grep 'test suite' | grep -o '[0-9]\{3\}' | head -1)
if [ -n "$AGENTS_SHELL" ] && [ -n "$ARCH_SHELL" ]; then
    if [ "$AGENTS_SHELL" != "$ARCH_SHELL" ]; then
        ERRORS="${ERRORS}ERROR: AGENTS.md shell test count ($AGENTS_SHELL) differs from ARCHITECTURE.md ($ARCH_SHELL)\n"
    fi
fi

# ── 10. No edit-tool anchor artifacts in tracked docs ───────────────
ANCHOR_CORRUPT=$(grep -l '[0-9][0-9][a-z][a-z]|' \
    ARCHITECTURE.md CHANGELOG.md AGENTS.md README.md 2>/dev/null || true)
if [ -n "$ANCHOR_CORRUPT" ]; then
    for f in $ANCHOR_CORRUPT; do
        LINES=$(grep -c '[0-9][0-9][a-z][a-z]|' "$f")
        ERRORS="${ERRORS}ERROR: $f has $LINES line(s) with edit-tool anchor artifacts (NNLL| pattern)\n"
    done
fi
# ── Report ─────────────────────────────────────────────────────────
if [ -n "$ERRORS" ]; then
    printf "$ERRORS"
    echo ""
    echo "Doc sync check FAILED. Fix the above issues."
    exit 1
fi

echo "Doc sync check passed. All docs match code."
exit 0

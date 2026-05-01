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
MODULE_COUNT=$(grep -c 'inherit ' bin/Pmp.pmod/module.pmod 2>/dev/null || echo 0)
if [ "$MODULE_COUNT" -eq 0 ]; then
    ERRORS="${ERRORS}ERROR: Cannot count modules in bin/Pmp.pmod/module.pmod\n"
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

# ── 4. Layer directory consistency ────────────────────────────────
LAYERS="core transport store project commands"
for layer in $LAYERS; do
    if [ ! -d "bin/$layer" ]; then
        ERRORS="${ERRORS}ERROR: Expected layer directory bin/$layer does not exist\n"
    fi
done

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

# ── Report ─────────────────────────────────────────────────────────
if [ -n "$ERRORS" ]; then
    printf "$ERRORS"
    echo ""
    echo "Doc sync check FAILED. Fix the above issues."
    exit 1
fi

echo "Doc sync check passed. All docs match code."
exit 0

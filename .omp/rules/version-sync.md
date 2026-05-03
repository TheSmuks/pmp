# Version Sync

**Type:** Scope-based rule
**Trigger:** Activates when `Config.pmod` is edited

## Scope

Matches files:
- `bin/Pmp.pmod/Config.pmod`

## When triggered

When editing `Config.pmod`, the agent **MUST**:

1. **Sync `PMP_VERSION`** with `pike.json`'s `"version"` field — They must match exactly

2. **Update `CHANGELOG.md`** — If version changed, add entry under `[Unreleased]` with version bump classification (major/minor/patch)

## Rationale

The `PMP_VERSION` constant in `Config.pmod` is the source of truth for pmp's version. Any version bump must be reflected in both places:

- `Config.pmod`: `constant PMP_VERSION = "X.Y.Z";`
- `pike.json`: `"version": "X.Y.Z"`

Keeping these in sync ensures consistent version reporting across CLI (`pmp version`), documentation, and lockfile generation.
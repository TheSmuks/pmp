# 0004: Semver Range Constraints in pike.json

**Status**: Proposed
**Date**: 2026-04-30
**Decision Maker**: @TheSmuks

## Context

pike.json dependencies are pinned to exact versions:

```json
{
  "dependencies": {
    "my-dep": "github.com/owner/repo#v1.2.3"
  }
}
```

The `#` suffix in a source string is extracted by `source_to_version` (Source.pmod) and used as-is — either as an exact tag match or left empty (which triggers "latest tag" resolution via `latest_tag` in Resolve.pmod). There is no constraint satisfaction, no range resolution, and no concept of "compatible with."

This means:

- Every dependency update requires manually editing pike.json to change the pinned version.
- There is no way to express "any 1.x" or "at least 1.2.0" — you either pin exactly or float to latest (including across major versions).
- `cmd_update` can report newer versions but cannot automatically select within a constraint range.

The existing infrastructure provides a strong foundation: `Semver.pmod` has `parse_semver`, `compare_semver`, and `sort_tags_semver`. Resolve.pmod's `_resolve_tags` already paginates all remote tags and sorts them by semver (highest first). The change is a constraint layer on top, not a rewrite.

## Decision

Support semver range constraint syntax in the version part of dependency source strings (the portion after `#`). The constraint is parsed from the version string; the rest of the source URL is unchanged.

### Supported constraint syntax

Following npm conventions (familiar to the broadest developer audience):

| Syntax | Meaning | Examples |
|--------|---------|---------|
| **Exact** | Exact tag match (current behavior) | `v1.2.3`, `1.2.3` |
| **Caret** `^` | Compatible with: same leftmost non-zero | `^1.2.3` → `>=1.2.3 <2.0.0` |
| | | `^0.2.3` → `>=0.2.3 <0.3.0` |
| | | `^0.0.3` → `>=0.0.3 <0.0.4` |
| **Tilde** `~` | Approximately: patch-level changes | `~1.2.3` → `>=1.2.3 <1.3.0` |
| **Range** | Explicit bounds | `>=1.0.0 <2.0.0` |
| **Wildcard** `*` | Any version | `1.*` → `>=1.0.0 <2.0.0` |

### pike.json format (backward compatible)

```json
{
  "dependencies": {
    "pinned": "github.com/owner/repo#v1.2.3",
    "caret": "github.com/owner/repo#^1.2.0",
    "tilde": "github.com/other/repo#~2.1.0",
    "range": "github.com/owner/repo#>=1.0.0 <2.0.0",
    "latest": "github.com/owner/repo"
  }
}
```

Exact versions (with or without `v` prefix) and empty version (no `#`) retain their current behavior. No migration needed for existing pike.json files.

### New Semver.pmod functions

```
parse_range(string spec) → mapping|0
```
Parses a constraint specifier into an internal representation. Returns 0 if unparseable. The mapping contains enough information for `version_satisfies` to evaluate any tag against it.

```
version_satisfies(string tag, mapping constraint) → int(0..1)
```
Checks whether a semver tag satisfies a parsed constraint. Returns 1 if the tag falls within the constraint bounds, 0 otherwise.

### Integration points

Four functions need changes, all minimal:

1. **`source_to_version`** (Source.pmod) — currently returns the raw string after `#`. No change to its return value. The caller (`install_one`) will pass this string to `parse_range` to determine whether it's a constraint or an exact pin.

2. **`install_one`** (Install.pmod) — the `ver == ""` branch resolves latest. After this change, when `ver` is a constraint (detected via `parse_range`), the resolution path fetches all tags (already done by `_resolve_tags`), filters by `version_satisfies`, and picks the highest matching tag instead of the absolute highest.

3. **`_resolve_tags`** (Resolve.pmod) — currently returns the single highest semver tag. No signature change needed: `install_one` can use the existing tag list or a new variant that returns all tags. The simplest approach is a new function `resolve_matching_tag(type, domain, repo_path, constraint)` that reuses pagination logic and applies the constraint filter before selecting.

4. **`validate_version_tag`** (Source.pmod) — must allow constraint operators (`^`, `~`, `>=`, `<`, `*`, whitespace) in addition to version characters. The security checks (no `/`, `\`, `..`, `;`, `\0`, `\n`) remain.

5. **Lockfile** — always records the resolved exact version, never the constraint. The lockfile format is unchanged. `cmd_update` reads the constraint from pike.json, compares against the locked version, and can suggest upgrades within range.

## Consequences

### Positive

- Users can express version compatibility without manual pin updates.
- `cmd_update` gains the ability to upgrade within a constraint range (e.g., `^1.2.0` auto-selects `1.3.1` if available).
- Lockfile continues to record exact versions — reproducible builds are preserved.
- Fully backward compatible: existing pike.json files with exact pins or no version work unchanged.
- Implementation is small-scope: two new functions in Semver.pmod, modest changes to Install.pmod and Resolve.pmod.

### Negative

- **Network cost for range resolution.** When a constraint is present, all remote tags must be fetched and filtered (not just the latest). For GitHub-hosted repos, this means paginating through all tags. Mitigation: the lockfile pins the resolved version, so range resolution only happens on `install` (no lockfile entry) or `update`, not on every build.
- **Constraint parsing adds complexity to `source_to_version`.** The version string is now overloaded — it can be an exact tag or a constraint expression. This is contained by having `parse_range` return 0 for exact versions, which the caller treats as a pin.
- **Prerelease handling.** Per npm/semver conventions, range constraints exclude prerelease versions unless the constraint itself contains a prerelease. This must be documented and tested.
- **`validate_version_tag` relaxation.** Allowing `>`, `<`, `=`, `~`, `^`, `*`, and spaces in version strings expands the accepted character set. The existing security invariants (no path traversal, no shell metacharacters) are preserved.

### Neutral

- The constraint syntax follows npm conventions. This is arbitrary but pragmatic — most developers have encountered it.
- No change to `parse_deps` (Manifest.pmod). It returns `({name, source})` pairs; the constraint is embedded in the source string and extracted downstream.

## Alternatives Considered

### Minimal: tilde-only

Support only `~1.2.3` (patch-level) and exact pins. Simpler to implement and reason about, but most dependency managers support caret ranges for good reason — major-version compatibility is the common case. Would likely lead to feature requests to add caret within weeks.

### Cargo-style `version = "1.2.3"` (bare version = caret)

Cargo treats a bare `1.2.3` as `^1.2.3`. This is elegant but breaks backward compatibility: existing pike.json files with `#v1.2.3` would silently change meaning from "exact pin" to "any compatible 1.x." Rejected for this reason alone.

### Separate constraints field

```json
{
  "dependencies": {
    "my-dep": {
      "source": "github.com/owner/repo",
      "version": "^1.2.0"
    }
  }
}
```

Cleaner separation, but changes the pike.json schema from string values to object values. Every consumer of `parse_deps` would need updating. The `#suffix` convention is already established; extending it is less disruptive.

## Implementation Steps

1. **`parse_range` in Semver.pmod** — Parse constraint specifiers into an internal mapping. Handle caret, tilde, explicit ranges, wildcards. Return 0 for exact versions (so the caller knows to treat it as a pin).

2. **`version_satisfies` in Semver.pmod** — Evaluate a parsed semver tag against a constraint mapping. Use the existing `compare_semver` for version comparisons.

3. **Tests for parse_range and version_satisfies** — Cover all constraint types, edge cases (0.x caret semantics, prerelease exclusion, invalid input).

4. **Update `validate_version_tag`** (Source.pmod) — Allow constraint operators and whitespace while preserving security invariants.

5. **Add `resolve_matching_tag`** (Resolve.pmod) — Variant of `_resolve_tags` that accepts a constraint, fetches all tags, filters by `version_satisfies`, and returns the highest match. Can reuse the existing pagination logic.

6. **Update `install_one`** (Install.pmod) — After `source_to_version`, call `parse_range`. If it returns a constraint, use `resolve_matching_tag` instead of `latest_tag`. If it returns 0, treat as exact pin (current behavior).

7. **Update `cmd_update`** (Update.pmod) — When a constraint exists, filter upgrade candidates to those satisfying the constraint. Currently compares against absolute latest; change to compare against highest within range.

8. **Integration tests** — End-to-end tests covering: exact pin, caret range, tilde range, range with no matching tags, constraint on repo with only prerelease tags.

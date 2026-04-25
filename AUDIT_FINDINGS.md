# Production Readiness Audit: Semver, Manifest, Project Modules

**Date**: 2026-04-23
**Scope**: `bin/Pmp.pmod/Semver.pmod`, `bin/Pmp.pmod/Manifest.pmod`, `bin/Pmp.pmod/Project.pmod`
**Auditor**: Adversarial — assuming broken until proven correct.

---

## Summary

21 findings across 3 modules. 6 critical (semver spec violations), 7 high (correctness/reliability), 5 medium (edge cases), 3 standardization issues. Three ACID violations identified in cmd_remove and cmd_clean.

---

## Critical — Semver Spec Violations

### S-01: Leading zeros not rejected
**File**: `Semver.pmod:38-44`
**Severity**: CRITICAL
**Semver Spec §2**: "Numeric identifiers MUST NOT include leading zeroes."

`parse_semver("01.2.3")` returns a valid mapping `{major: 1, minor: 2, patch: 3}` instead of `0`. The digit-check loop (line 38-44) verifies characters are digits but never rejects multi-digit numbers starting with `"0"`. `sscanf("01", "%d", major)` silently strips the leading zero.

**BEHAVIOR_SPEC.md** documents the expected behavior as `returns 0`. The code contradicts the spec. Test `test_parse_leading_zeros` (SemverTests.pike:94) asserts the wrong behavior.

```pike
// Current — no leading-zero check:
foreach (p / 1; ; string c)
    if (c < "0" || c > "9") { dig = 0; break; }
// Missing: sizeof(p) > 1 && p[0] == '0'
```

**Fix**: After the digit loop, add: `if (sizeof(p) > 1 && p[0] == '0') return 0;`

---

### S-02: Empty prerelease after dash accepted
**File**: `Semver.pmod:26-31`
**Severity**: CRITICAL
**Semver Spec §9**: A pre-release version "MAY be denoted by appending a hyphen and a series of dot separated identifiers." The hyphen must be followed by at least one non-empty identifier.

`parse_semver("1.2.3-")` returns a valid mapping with `prerelease: ""`. The dash splits into `v = "1.2.3"` and `pre = ""`, and the empty prerelease is stored without validation.

**BEHAVIOR_SPEC.md** documents: `"1.2.3-" → returns 0`. Code and test (`test_parse_trailing_dash`, SemverAdversarialTests.pike:10) contradict this.

**Fix**: After splitting off prerelease (line 31), add:
```pike
if (pre_idx >= 0 && sizeof(pre) == 0) return 0;
```

---

### S-03: One- and two-part versions accepted
**File**: `Semver.pmod:34-35, 46-49`
**Severity**: CRITICAL
**Semver Spec §2**: "A normal version number MUST take the form X.Y.Z."

`parse_semver("1")` returns `{major:1, minor:0, patch:0}` and `parse_semver("1.2")` returns `{major:1, minor:2, patch:0}`. The check `sizeof(parts) < 1` allows 1 part; `sizeof(parts) > 3` allows 2 parts. Default values fill missing components.

BEHAVIOR_SPEC.md documents this as intentional ("treated as 1.0.0" / "treated as 1.2.0"). This is a deliberate deviation from strict semver — acceptable if documented, but should be a conscious decision with a comment in the code explaining why.

**Current code has no comment explaining the deviation.**

**Fix**: Either reject partial versions (`if (sizeof(parts) != 3) return 0;`) or add a comment documenting the intentional deviation.

---

### S-04: Prerelease identifiers not validated
**File**: `Semver.pmod:26-31`
**Severity**: CRITICAL
**Semver Spec §9**: "Identifiers MUST comprise only ASCII alphanumerics and hyphens [0-9A-Za-z-]. Identifiers MUST NOT be empty."

No validation occurs on the prerelease string after extraction. The following all parse without error:
- `"1.0.0-\t"` — tab in prerelease
- `"1.0.0-alpha/beta"` — slash (not in [0-9A-Za-z-])
- `"1.2.3-alpha..beta"` — empty identifier between dots
- `"1.0.0-"` — empty identifier (see S-02)
- `"1.0.3-\x03b1\x03b2"` — Unicode characters

Tests acknowledge this with comments like "parser doesn't validate prerelease format" but it remains a spec violation that could produce incorrect comparisons downstream.

**Fix**: Add a validation function for prerelease identifiers:
```pike
int valid_prerelease_id(string id) {
    if (sizeof(id) == 0) return 0;
    foreach (id / 1; ; string c)
        if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "z")
            || (c >= "A" && c <= "Z") || c == "-"))
            return 0;
    return 1;
}
```
Call it on each dot-separated identifier after extraction.

---

### S-05: Build metadata identifiers not validated
**File**: `Semver.pmod:20-23`
**Severity**: CRITICAL
**Semver Spec §10**: "Build metadata identifiers MUST comprise only ASCII alphanumerics and hyphens [0-9A-Za-z-]. Identifiers MUST NOT be empty."

Build metadata is stripped and silently discarded. `"1.0.0+"` (empty metadata), `"1.0.0+build/stuff"` (slash), `"1.0.0+."` (empty identifier) all parse without error. While build metadata doesn't affect comparison, accepting invalid input means parse_semver returns success for strings that aren't valid semver.

**Fix**: Before stripping build metadata, validate it (same rules as prerelease, per spec §10). Alternatively, reject versions with build metadata that contains invalid characters.

---

### S-06: Prerelease numeric leading zeros not validated
**File**: `Semver.pmod:26-31`
**Severity**: CRITICAL
**Semver Spec §9**: "Numeric identifiers MUST NOT include leading zeroes."

`parse_semver("1.0.0-01")` returns a valid mapping with `prerelease: "01"`. While `compare_prerelease` correctly handles this via its round-trip numeric detection (`pa[i] == (string)a_val`), the parser should reject it outright.

**Fix**: In the prerelease validation (S-04), add a check: if a dot-separated identifier is all digits and starts with "0" and has length > 1, reject.

---

## High — Correctness / Reliability

### S-07: Non-semver tags may reorder in sort
**File**: `Semver.pmod:142`
**Severity**: HIGH

When both tags are non-semver, the comparator returns `0` (equal). `Array.sort_array` is not guaranteed stable, so relative ordering of non-semver tags is undefined. If callers rely on non-semver tag order (e.g., "nightly" before "latest"), it could change between Pike versions.

**Impact**: Low — non-semver tags are typically treated as equivalent. But if any downstream logic uses index positions within the non-semver tail, it could break.

---

### M-01: add_to_manifest has no success/failure signal
**File**: `Manifest.pmod:10-39`
**Severity**: HIGH

Returns `void`. Caller cannot distinguish four outcomes:
1. Dependency added (success)
2. Dependency already present (no-op, early return line 29)
3. File not found (warn + return)
4. Parse error (warn + return)

Callers like `cmd_install` cannot verify the manifest was actually updated. If pike.json is corrupt or missing, the install proceeds as if it succeeded.

**Fix**: Return an integer or enum: 0=success, 1=already-present, -1=error. Or throw on error instead of silent warn+return.

---

### M-02: add_to_manifest accepts unvalidated name and source
**File**: `Manifest.pmod:10`
**Severity**: HIGH

No validation on `name` or `source` parameters. A name containing `/`, `..`, or `\0` could be stored in pike.json, creating a dependency entry that `cmd_remove` can't match (since cmd_remove strips `.pmod` and checks for path traversal). Empty strings are also accepted.

**Fix**: Validate name against the same rules used in cmd_remove (no `/`, `..`, `\0`, not empty). Validate source is a non-empty string.

---

### P-01: cmd_remove — non-atomic three-step modification (ACID violation)
**File**: `Project.pmod:111-171`
**Severity**: HIGH

Three independent state modifications:
1. **pike.json** — atomic write via `atomic_write` (line 133)
2. **Symlinks** — `rm(link)` and `rm(link_pmod)` (lines 146, 151)
3. **Lockfile** — `write_lockfile` via `atomic_write` (line 166)

Failure scenarios:
- Step 1 succeeds, step 2 fails → pike.json says removed, but symlink still exists
- Steps 1-2 succeed, step 3 fails (write_lockfile calls die) → pike.json and filesystem updated, lockfile stale or corrupt
- Step 3 dies after modifying ctx["lock_entries"] but before atomic_write completes → inconsistent state

**Fix**: Perform all validations first, then execute in reverse-dependency order: (1) backup lockfile, (2) update lockfile, (3) remove symlinks, (4) update pike.json. On any failure, restore from backup. Alternatively, use a transaction log file.

---

### P-02: cmd_remove — lockfile rewritten unconditionally
**File**: `Project.pmod:157-167`
**Severity**: HIGH

When the lockfile exists, lines 157-167 execute regardless of whether the removed dependency was in the lockfile. If `had_entry` is 0 (dep not in lockfile), `new_entries` equals `entries` — a no-op rewrite. But `write_lockfile` still:
- Validates all fields (could die on corrupt entries)
- Creates a .prev backup
- Rewrites the file atomically

If validation dies, the function exits after pike.json was already modified. This is an ACID violation — pike.json is updated but the process dies before reaching the "removed" message.

**Fix**: Only enter the lockfile block if the dependency name appears in the lockfile entries.

---

### P-03: cmd_clean — count incremented before removal attempted
**File**: `Project.pmod:86-102`
**Severity**: HIGH

Count is incremented in the first pass (line 92) but removal happens in the second pass (line 101). If `rm()` fails (permissions, read-only filesystem), the count is wrong and no error is reported. The user sees "cleaned N modules" but some remain.

**Fix**: Remove in a single pass. Attempt removal, check return value, increment count only on success. Report failures.

---

### P-04: cmd_clean — no store orphan cleanup
**File**: `Project.pmod:81-109`
**Severity**: HIGH (resource leak)

After cleaning symlinks from the local modules directory, the store entries they pointed to remain in `~/.pike/store/`. Over time, repeated install/clean cycles accumulate orphaned store entries consuming disk space. The `cmd_store prune` command exists for this, but `cmd_clean` doesn't mention it or offer to run it.

**Fix**: After cleaning, warn if store has orphaned entries. Or integrate prune into clean (with a flag to opt out).

---

## Medium — Edge Cases / Improvements

### S-08: Build metadata lost after parsing
**File**: `Semver.pmod:20-23`
**Severity**: MEDIUM

Build metadata is stripped and not stored in the returned mapping. While correct for comparison (spec §10), callers who need the full original version (e.g., for display) must use the `original` field and re-parse. The `original` field preserves the full string, but there's no way to extract just the build metadata.

**Impact**: Low — `original` field preserves the complete string. But if someone wants to compare build metadata (allowed, just not for precedence), they can't.

---

### M-03: parse_deps silently swallows malformed dependencies
**File**: `Manifest.pmod:46-66`
**Severity**: MEDIUM

Returns `({})` for: missing file, unreadable file, invalid JSON, non-mapping JSON, missing dependencies key, non-mapping dependencies, non-string dep values, empty string sources. In all cases: no warning, no logging, no indication of the problem.

If a user has a typo in their pike.json (e.g., `"dependancies": {...}`), `parse_deps` returns empty and `cmd_install_all` silently installs nothing. No error, no warning.

**Fix**: At minimum, warn when JSON parses successfully but `dependencies` is missing or wrong type. Return an error indicator, not just empty array.

---

### P-05: cmd_init — TOCTOU on pike.json existence
**File**: `Project.pmod:8-10`
**Severity**: MEDIUM

```pike
if (Stdio.exist(ctx["pike_json"]))
    die("pike.json already exists in this directory");
// ... then writes to ctx["pike_json"]
```

Between the check and the write, another process could create pike.json. Low severity because `pmp init` is typically interactive, but in scripted/CI environments this could cause data loss (overwriting a just-created file).

**Fix**: Use `O_EXCL` open or attempt atomic_write and check for existence after.

---

### P-06: cmd_init — getcwd() may return 0
**File**: `Project.pmod:13`
**Severity**: MEDIUM

```pike
string dir_name = (getcwd() / "/")[-1];
```

If the CWD has been deleted (parent process removed the directory), `getcwd()` throws or returns 0. The `/` operator on 0 would crash. The fallback `basename(getcwd())` on line 15 has the same issue.

**Fix**: Wrap in catch or check for 0 before string operations.

---

### P-07: cmd_list — empty .version file shows "(unknown)"
**File**: `Project.pmod:64`
**Severity**: MEDIUM

```pike
ver = Stdio.read_file(ver_file) || "(unknown)";
```

In Pike, empty string `""` is falsy. If `.version` exists but is empty, `read_file` returns `""`, which triggers the `||` fallback to `"(unknown)"`. This is reasonable behavior but undocumented and could confuse users who accidentally created empty .version files.

---

### P-08: cmd_remove — no transitive dependency check
**File**: `Project.pmod:111`
**Severity**: MEDIUM

Removing a dependency that's required by another installed package succeeds without warning. For example, if A depends on B, and user runs `pmp remove B`, the removal succeeds but A is now broken.

**Impact**: Moderate — the lockfile will reflect the removal, but the user has no indication that A is now broken until runtime.

**Fix**: Before removing, check if any other installed dependency's source matches the one being removed. If so, warn (but don't block — user may know what they're doing).

---

## Standardization Issues

### X-01: BEHAVIOR_SPEC.md contradicts actual behavior

| Scenario | BEHAVIOR_SPEC says | Code does |
|---|---|---|
| `"01.2.3"` (leading zeros) | returns 0 | returns valid mapping |
| `"1.2.3-"` (empty prerelease) | returns 0 | returns valid mapping |
| `"1"` (single part) | accepted as 1.0.0 | accepted (no comment explaining deviation) |

The spec is the contract. When spec and code disagree, one of them is wrong.

**Fix**: Decide whether to fix the code or update the spec. Either way, bring them into agreement.

---

### X-02: Inconsistent error handling across modules

| Module | Strategy | Caller impact |
|---|---|---|
| Semver | Returns 0 on error | Must check for 0 |
| Manifest.add_to_manifest | warn + return void | Cannot detect failure |
| Manifest.parse_deps | Silent return `({})` | Cannot distinguish empty from error |
| Project (init/list/clean) | die() on error | Process exits |
| Project (remove) | die() on some errors, silent on others | Partial failure undetectable |

There's no consistent contract. Callers must know which strategy each function uses, and some strategies (silent return) make it impossible to detect problems.

**Fix**: Adopt a consistent approach. Recommendation: return error indicators (0, empty, or error mapping) for recoverable errors; die() only for truly unrecoverable states. Never silently swallow errors.

---

### X-03: No centralized dependency name validation

Name validation is fragmented:
- `cmd_remove` (Project.pmod:120): rejects `/`, `..`, `\0`
- `add_to_manifest` (Manifest.pmod:10): no validation
- `parse_deps` (Manifest.pmod:46): no validation on names from JSON
- `cmd_init` (Project.pmod:13): derives name from directory — no validation

A name with special characters can be stored via `add_to_manifest` but cannot be removed via `cmd_remove` (if it contains `/` or `..`).

**Fix**: Extract a shared `validate_dep_name(string name)` function. Call it in add_to_manifest and any entry point that accepts a dependency name.

---

## ACID Violations — Detailed

### ACID-1: cmd_remove — Atomicity violated
**Location**: `Project.pmod:125-167`
**Scenario**: pike.json updated → symlink removal fails → lockfile updated
**Result**: Dependency removed from manifest and lockfile but symlink still exists. Next `pmp install` will skip it (not in pike.json) but the symlink resolves, potentially loading stale code.

### ACID-2: cmd_remove — Atomicity violated (lockfile die)
**Location**: `Project.pmod:166`
**Scenario**: pike.json updated → symlink removed → write_lockfile dies (validation error in another entry)
**Result**: Process exits with EXIT_INTERNAL. Pike.json and filesystem are updated, lockfile may be in any state (atomic_write temp file may exist, .prev backup exists). On restart, lockfile and pike.json are inconsistent.

### ACID-3: cmd_clean — Inconsistent reporting
**Location**: `Project.pmod:86-108`
**Scenario**: Count symlinks in pass 1 (N=5), remove in pass 2 (3 succeed, 2 fail due to permissions)
**Result**: User sees "cleaned 5 modules" but 2 remain. Modules directory may or may not be removed (depends on has_non_symlink which was computed in pass 1 — stale by pass 2).

---

## Priority-Ranked Fix Plan

### Phase 1 — Critical spec violations (block release)

| # | Finding | Fix | Acceptance |
|---|---------|-----|------------|
| 1 | S-01: Leading zeros | Add `sizeof(p) > 1 && p[0] == '0'` check | `parse_semver("01.2.3") == 0` |
| 2 | S-02: Empty prerelease | Add `sizeof(pre) == 0 && pre_idx >= 0 → return 0` | `parse_semver("1.2.3-") == 0` |
| 3 | S-04: Prerelease validation | Validate [0-9A-Za-z-] in each dot-ident | `parse_semver("1.0.0-alpha/beta") == 0` |
| 4 | S-06: Prerelease numeric leading zeros | Check for leading zeros in numeric prerelease ids | `parse_semver("1.0.0-01") == 0` |
| 5 | X-01: Spec/code alignment | Fix code to match BEHAVIOR_SPEC or update spec | All BEHAVIOR_SPEC cases pass |

### Phase 2 — High-severity correctness (block production use)

| # | Finding | Fix | Acceptance |
|---|---------|-----|------------|
| 6 | P-01: cmd_remove atomicity | Reverse-order execution + rollback on failure | Removing a dep either fully succeeds or fully rolls back |
| 7 | P-02: Unconditional lockfile rewrite | Guard with `had_entry` check | Lockfile not touched when dep not in lockfile |
| 8 | P-03: cmd_clean count mismatch | Single-pass remove + count | Count matches actual removals |
| 9 | M-01: add_to_manifest silent failure | Return status code | Caller can detect all four outcomes |
| 10 | M-02: No name validation in add_to_manifest | Extract shared validate_dep_name | Invalid names rejected |

### Phase 3 — Medium-severity improvements

| # | Finding | Fix | Acceptance |
|---|---------|-----|------------|
| 11 | S-03: Partial versions | Require 3 parts or document deviation with comment | Decision documented in code |
| 12 | S-05: Build metadata validation | Validate build metadata identifiers | Invalid metadata rejected |
| 13 | M-03: parse_deps silent errors | Warn on malformed dependencies | User sees warning for invalid deps |
| 14 | X-02: Inconsistent error handling | Adopt consistent return-or-die policy | Every function follows the pattern |
| 15 | X-03: Centralized name validation | Extract validate_dep_name | All entry points validate |

### Phase 4 — Nice-to-have

| # | Finding | Fix |
|---|---------|-----|
| 16 | P-04: Store orphan cleanup after clean | Warn or auto-prune |
| 17 | P-06: getcwd() safety | Wrap in catch |
| 18 | P-08: Transitive dep check on remove | Warn before removing required dep |
| 19 | S-07: Non-semver tag ordering | Document as undefined |

---

## Metrics

| Category | Count |
|---|---|
| **Critical (spec violations)** | 6 |
| **Errors (bugs, logic flaws)** | 7 |
| **ACID violations** | 3 |
| **Standardization issues** | 3 |
| **Improvements** | 5 |
| **Total findings** | 21 |
| **Phase 1 (blocking)** | 5 |
| **Phase 2 (high)** | 5 |
| **Phase 3 (medium)** | 5 |
| **Phase 4 (low)** | 4 |

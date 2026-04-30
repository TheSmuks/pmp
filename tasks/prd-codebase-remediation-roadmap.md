# PRD: PMP Codebase Remediation & Feature Roadmap

## Introduction

A full-spectrum audit of the pmp codebase (17 modules, 5 layers, 489 tests) reveals three categories of problems that must be addressed before pmp can serve as a reliable package manager for the Pike ecosystem:

1. **Correctness bugs** — stale transitive deps on single-module update, silent lockfile data loss, non-atomic remove operations, IPv6 SSRF bypass in `::1` expansion
2. **Architectural debt** — locking primitives in an orchestrator module, 60 lines of duplicated HTTP redirect logic, flat-inherit namespace pollution, `pmp lock` side-effecting installs
3. **Documentation drift** — version mismatch (0.3.0 in docs, 0.4.0 in code), stale test counts, layer count wrong, aspirational style guide not followed

Beyond fixing what exists, this roadmap plans the features needed for pmp to approach the bar set by cargo, uv, and bun: workspaces, lockfile v2 with integrity, offline mode, and semver range constraints.

**Verified test baseline (2026-04-30):** 172 shell tests pass, 317 Pike unit tests pass, 0 failures. All 17 modules have zero dead public functions. Every production symbol is exercised by tests.

---

## Goals

1. Every document matches reality — version numbers, test counts, module lists, function signatures
2. All correctness bugs fixed with regression tests — no silent data loss, no stale state, no non-atomic operations
3. Security posture hardened — SSRF, credential leakage, path traversal gaps closed
4. Architectural coherence — shared primitives in utility modules, no layering violations, no duplicated logic
5. Feature parity roadmap scoped — workspaces, lockfile v2, offline mode, semver ranges designed and prioritized

---

## Phase 1: Truth — Documentation Reconciliation

*Zero risk. No code behavior changes. Pure documentation and metadata.*

### US-101: Reconcile all documentation with verified codebase state
**Description:** As a developer, I want all documentation to accurately reflect the actual codebase so I'm not misled when onboarding or debugging.

**Acceptance Criteria:**
- [ ] ARCHITECTURE.md version changed from 0.3.0 to 0.4.0
- [ ] ARCHITECTURE.md layer count changed from "4 layers" to "5 layers" (core, transport, store, project, commands)
- [ ] CHANGELOG.md stale claim "14 modules" corrected to "17 modules"
- [ ] AGENTS.md Pike test count corrected from 306/373 to 317
- [ ] pmp.pike line 4 stale comment updated: `// Commands live in bin/commands/, bin/project/, bin/store/` instead of referencing old flat layout
- [ ] Install.pmod line 1-2 stale comment fixed: remove claim that cmd_update/cmd_lock/cmd_rollback/cmd_changelog live in Install.pmod
- [ ] docs/TIGER_STYLE.md annotated or replaced with Pike-applicable subset — current copy is a verbatim Zig style guide
- [ ] AGENTS.md references to Cache.pmod in CHANGELOG reconciliation bullet clarified (historical, not current)
- [ ] This PRD replaces the previous tasks/prd-codebase-remediation-roadmap.md

### US-102: Remove aspirational TODO in ConfigTests.pike
**Description:** As a developer, I want no commented-out tests referencing nonexistent constants or nonexistent files.

**Acceptance Criteria:**
- [ ] ConfigTests.pike TODO about LOCK_MAX_ATTEMPTS_STORE/LOCK_MAX_ATTEMPTS_PROJECT/LOCK_BACKOFF_BASE removed or converted to a tracked issue
- [ ] Reference to nonexistent "behavior-spec.md" removed
- [ ] All 317 Pike tests still pass

---

## Phase 2: Correctness — Fix Real Bugs

*These fix observed or provable bugs. Each fix gets a regression test.*

### US-201: Fix `pmp update <module>` stale transitive dep accumulation
**Description:** As a user, I want `pmp update <module>` to prune transitive deps that are no longer required, the same way `pmp install` does — so my lockfile stays minimal.

**Root cause:** `cmd_update` single-module path (Update.pmod L54-103) calls `install_one` and merges new entries, but never runs the BFS pruning logic that exists only in `cmd_install_all` (Install.pmod L462-494).

**Acceptance Criteria:**
- [ ] Extract BFS prune logic from `cmd_install_all` into a shared function (e.g., `prune_stale_deps` in Lockfile.pmod or Helpers.pmod)
- [ ] `cmd_update` single-module path calls the shared prune function after merging
- [ ] New test: install module A (depends on B v1.0), update A to version that depends on B v2.0, verify B v1.0 pruned from lockfile
- [ ] New test: install module A (depends on C), update A to version with no C dep, verify C pruned
- [ ] All 172+317 existing tests pass

### US-202: Fix lockfile silent data loss on malformed input
**Description:** As a user, I want corrupt or unrecognized lockfile entries to produce clear errors, not silently vanish.

**Root cause:** `merge_lock_entries` silently skips entries with empty names. `read_lockfile` warns but continues on unrecognized format.

**Acceptance Criteria:**
- [ ] `merge_lock_entries` dies with clear error when encountering entries with empty names instead of silently dropping them
- [ ] `read_lockfile` dies (not warns) when the lockfile version header is unrecognized — a completely different format should not be silently parsed
- [ ] `lockfile_add_entry` validates that name and source fields are non-empty before appending
- [ ] New tests for each validation path
- [ ] All existing tests pass

### US-203: Fix non-atomic `pmp remove` operation
**Description:** As a user, I want `pmp remove <module>` to either fully succeed or fully roll back — never leave the project in a half-removed state.

**Root cause:** `cmd_remove` (Project.pmod) removes symlink, then edits pike.json, then rewrites lockfile — three separate operations with no rollback on failure.

**Acceptance Criteria:**
- [ ] `cmd_remove` snapshots state before mutation (symlink target, pike.json content, lockfile content)
- [ ] On any failure after the first mutation, restore all mutated artifacts to snapshot state
- [ ] New test: mock pike.json write failure, verify symlink restored and pike.json unchanged
- [ ] New test: mock lockfile write failure, verify symlink and pike.json restored
- [ ] All existing tests pass

### US-204: Fix `pmp lock` side-effecting installs
**Description:** As a user, I want `pmp lock` to resolve and write the lockfile WITHOUT installing modules — like `cargo generate-lockfile` or `npm shrinkwrap`.

**Root cause:** `cmd_lock` (LockOps.pmod) calls `install_one` which downloads, extracts, symlinks, and writes lock entries. It should resolve without installing.

**Acceptance Criteria:**
- [ ] `install_one` split into `resolve_one` (version resolution + SHA lookup) and `install_one` (resolve + download + symlink)
- [ ] `cmd_lock` calls `resolve_one` instead of `install_one`
- [ ] `pmp lock` does NOT create symlinks in `modules/`
- [ ] `pmp lock` does NOT download to store (uses existing store entries if available, resolves remotely otherwise)
- [ ] Existing `pmp lock` shell tests updated if behavior changes
- [ ] All tests pass

### US-205: Fix `_read_json_mapping` silent failure on malformed JSON
**Description:** As a developer, I want corrupt `pike.json` to produce a clear parse error, not a confusing "file not found" downstream.

**Root cause:** `_read_json_mapping` returns 0 on both "file missing" and "file has malformed JSON". Callers cannot distinguish the cases.

**Acceptance Criteria:**
- [ ] `_read_json_mapping` returns different sentinel values or throws on parse error vs file-not-found
- [ ] Callers produce appropriate error messages: "pike.json has invalid JSON" vs "pike.json not found"
- [ ] New test: corrupt JSON file produces specific error message
- [ ] All existing tests pass

### US-206: Fix `classify_bump` prerelease-to-release hole
**Description:** As a developer, I want `classify_bump("1.0.0-alpha", "1.0.0")` to return "prerelease" (it does), and the same-version-same-prerelease case handled explicitly.

**Root cause:** Works for the common case but the prerelease→release transition path is reached via fallthrough, not explicit logic. If both versions are identical (including prerelease), the function returns "none" — which is correct but fragile.

**Acceptance Criteria:**
- [ ] `classify_bump` has explicit branches for: major bump, minor bump, patch bump, prerelease change, prerelease→release, release→prerelease, same version, downgrade
- [ ] No fallthrough logic — every comparison path has an explicit condition
- [ ] Existing 30 Semver adversarial tests pass
- [ ] New test for explicit prerelease→release with same major.minor.patch

---

## Phase 3: Security — Harden Attack Surface

### US-301: Fix SSRF bypass via IPv6 `::1` expansion
**Description:** As a developer, I want the SSRF protection to correctly block all loopback addresses including `::1`.

**Root cause:** `_is_private_host` in Http.pmod (L159-177) has a bug in `::` expansion: empty prefix split by `:` gives `({"",})` (size 1), not `({})` (size 0). This overcounts existing groups by 1, producing only 6 fill groups for `::1` instead of 7, so the result is only 7 groups total (not 8) and the loopback check fails to match.

**Acceptance Criteria:**
- [ ] Fix `::` expansion to handle empty prefix/suffix correctly
- [ ] Add explicit check for `::1` before expansion (defense in depth)
- [ ] New test: `_is_private_host("::1")` returns true
- [ ] New test: `_is_private_host("::ffff:127.0.0.1")` returns true
- [ ] New test: `_is_private_host("0:0:0:0:0:0:0:1")` returns true
- [ ] New test: `_is_private_host("::")` returns true
- [ ] All existing HttpAdversarialTests pass

### US-302: Eliminate credential leakage in error messages
**Description:** As a user, I want error messages that contain URLs to never expose embedded credentials (tokens, passwords in `user:pass@host` URLs).

**Root cause:** `die()` and `warn()` are called with raw source URLs that may contain `https://token@github.com/...` or `https://user:pass@selfhosted/...`.

**Acceptance Criteria:**
- [ ] Add `sanitize_url(string url)` to Helpers.pmod — strips credentials from URLs before display
- [ ] Audit all `die()`, `warn()`, `info()` calls that include source URLs — use `sanitize_url`
- [ ] New test: `sanitize_url("https://token@github.com/owner/repo")` returns `"https://***@github.com/owner/repo"`
- [ ] New test: `sanitize_url("https://user:pass@host/path")` returns `"https://***@host/path"`
- [ ] New test: `sanitize_url("https://github.com/owner/repo")` returns unchanged

### US-303: Reject `file://` URLs with clear error message
**Description:** As a user, I want `file://` URLs to be explicitly rejected rather than silently mishandled.

**Rootance:** `detect_source_type` in Source.pmod doesn't recognize `file://` scheme. It falls through to "invalid source format" which is technically correct but the error message doesn't mention `file://` is unsupported.

**Acceptance Criteria:**
- [ ] `detect_source_type` checks for `file://` prefix and dies with "file:// URLs are not supported — use a local path instead"
- [ ] New test: `detect_source_type("file:///path/to/module")` dies with specific message
- [ ] All existing tests pass

### US-304: Add path traversal protection for local dep resolution
**Description:** As a user, I want local dependency paths in `pike.json` to be validated against path traversal after resolution — a malicious manifest should not be able to symlink to `/etc/passwd`.

**Root cause:** `install_one` checks for `..` in the raw source (L72) but not after `resolve_local_path` resolves symlinks. A resolved path could escape the project root.

**Acceptance Criteria:**
- [ ] After resolving local dep path, verify the resolved path is within the project root (or within a configured allowlist)
- [ ] Die with clear error if resolved path escapes project root
- [ ] New test: local dep with `../../etc/passwd` is rejected after resolution
- [ ] All existing tests pass

---

## Phase 4: Architecture — Reduce Coupling, Extract Shared Primitives

### US-401: Move project_lock/unlock to Helpers.pmod
**Description:** As a developer, I want locking primitives to live in the utility layer, not in an orchestrator — so LockOps and Update don't need to inherit the full Install module just to acquire a lock.

**Current state:** `project_lock`/`project_unlock` defined in Install.pmod (L48-55). LockOps.pmod and Update.pmod inherit `.Install` partly to access these. Store.pmod independently defines `store_lock`/`store_unlock`.

**Acceptance Criteria:**
- [ ] `project_lock`/`project_unlock` moved from Install.pmod to Helpers.pmod
- [ ] `store_lock`/`store_unlock` moved from Store.pmod to Helpers.pmod
- [ ] All locking lives in one place (Helpers.pmod alongside `advisory_lock`/`advisory_unlock`)
- [ ] Install.pmod, LockOps.pmod, Update.pmod, Project.pmod, Store.pmod all call Helpers for locking
- [ ] LockOps.pmod and Update.pmod may still inherit `.Install` for `install_one`/`cmd_install_all` — document why
- [ ] All 489 tests pass

### US-402: Deduplicate HTTP redirect/SSRF logic
**Description:** As a developer, I want HTTP redirect following and SSRF checking to exist in one place, not duplicated across `http_get` and `http_get_safe`.

**Current state:** Http.pmod has ~60 lines of near-identical redirect-following code in both functions. The only difference is error handling: `http_get` calls `die()`, `http_get_safe` returns 0.

**Acceptance Criteria:**
- [ ] Extract shared `_do_request(url, opts)` internal function that handles redirects, SSRF, retry
- [ ] `http_get` wraps `_do_request` and dies on error
- [ ] `http_get_safe` wraps `_do_request` and returns 0 on error
- [ ] No duplicated redirect/SSRF logic remains
- [ ] All 17 HttpAdversarialTests pass
- [ ] All 172 shell tests pass (includes network-dependent install tests)

### US-403: Deduplicate Resolve dying/safe variants
**Description:** As a developer, I want `latest_tag_github` and `latest_tag_github_safe` to share code, parameterized by error mode.

**Current state:** 6 near-duplicate functions (github, gitlab, github_safe, gitlab_safe) with identical URL construction but different error handling.

**Acceptance Criteria:**
- [ ] Refactor to use shared `_resolve_remote_tags(source, die_on_error)` that takes an error-mode flag
- [ ] `latest_tag_github`/`latest_tag_gitlab` call shared with `die_on_error=1`
- [ ] `latest_tag_github_safe`/`latest_tag_gitlab_safe` call shared with `die_on_error=0`
- [ ] All 18 ResolveAdversarialTests pass

### US-404: Unify orphan detection between StoreCmd and Verify
**Description:** As a developer, I want store orphan detection to live in one place, used by both `cmd_store prune` and `cmd_verify`.

**Current state:** `StoreCmd._entry_referenced` and `Verify` orphan detection are independent implementations of the same logic.

**Acceptance Criteria:**
- [ ] Extract `find_orphaned_entries(store_dir, project_dirs)` to Store.pmod
- [ ] `cmd_store prune` and `cmd_verify` both call the shared function
- [ ] Tests for both commands pass

---

## Phase 5: Feature Roadmap — Cargo/uv/bun-Inspired Features

*These are forward-looking features. Each requires its own design doc before implementation.*

### US-501: Workspaces (Monorepo Multi-Package Support)
**Description:** As a user with a monorepo containing multiple Pike packages, I want `pike.json` to support a `workspace` key that defines member packages — like cargo workspaces or bun workspaces.

**Design sketch:**
```json
{
  "name": "my-monorepo",
  "workspace": ["packages/*"],
  "dependencies": { "shared-dep": "github.com/org/dep#v1.0.0" }
}
```

**Scope:**
- Root `pike.json` with `"workspace"` array (glob patterns)
- `pmp install` at root installs for all workspace members
- Shared lockfile at root
- Workspace members can depend on each other via `"./sibling"` paths
- `pmp run --package <name>` to run scripts in specific workspace member
- `pmp list` shows workspace members

**Acceptance Criteria:**
- [ ] Design document written: `docs/decisions/0003-workspaces.md`
- [ ] `pike.json` schema extended with optional `"workspace"` key
- [ ] `find_project_root` discovers workspace root
- [ ] `parse_deps` reads member `pike.json` files
- [ ] Lockfile records workspace member origin
- [ ] `pmp install` resolves deps across all members
- [ ] `pmp list` shows workspace structure

### US-502: Lockfile v2 with Integrity Verification
**Description:** As a user, I want the lockfile to include integrity hashes for all entries and a top-level signature — like `cargo.lock` with content-addressable verification.

**Current state:** Lockfile v1 is tab-separated: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`. No top-level integrity, no version header enforcement, no signature.

**Design sketch:**
```
# pmp-lock-version: 2
name\tsource\ttag\tcommit_sha\tcontent_sha256\tintegrity
```
Where `integrity` is `sha256-<base64>` of the entire store entry directory (matching `compute_dir_hash`).

**Scope:**
- Version header mandatory (v1 or v2)
- `integrity` field added per entry
- Top-level `# checksum: <sha256-of-lockfile-body>` line
- `pmp verify` checks integrity of every entry against lockfile
- Backward-compatible read: v1 lockfiles auto-migrated on next write
- `pike.lock` renamed to `pmp.lock` (with `pike.lock` symlink for transition)

**Acceptance Criteria:**
- [ ] Design document: `docs/decisions/0004-lockfile-v2.md`
- [ ] Lockfile.pmod supports both v1 and v2 formats
- [ ] `write_lockfile` writes v2 format
- [ ] `read_lockfile` reads both v1 and v2
- [ ] `pmp verify` validates integrity field against store
- [ ] Migration path: existing `pike.lock` files auto-upgraded
- [ ] All existing tests pass with v1 lockfiles
- [ ] New tests for v2 format

### US-503: Offline Mode / Air-Gapped Installs
**Description:** As a user in an air-gapped environment, I want `pmp install --offline` to install exclusively from the content-addressable store and lockfile — never making network requests.

**Current state:** `--offline` flag exists (Install.pmod L522) and is passed through ctx, but the implementation is incomplete — `get_resolved_sha` returns `"-"` in offline mode but some code paths still attempt network requests.

**Scope:**
- `--offline` flag guaranteed to make zero network requests
- All resolve operations read from lockfile only
- Store entries must already exist (clear error if not)
- `pmp lock --offline` resolves from existing store entries only
- `pmp outdated --offline` reports "unavailable" instead of making API calls
- `pmp doctor --offline` skips network checks

**Acceptance Criteria:**
- [ ] Audit every network call path (http_get, http_get_safe, Process.run for git ls-remote) and verify `--offline` skips all of them
- [ ] `pmp install --offline` succeeds when all store entries exist and lockfile is present
- [ ] `pmp install --offline` dies with clear message when store entry missing
- [ ] `pmp outdated --offline` reports "network unavailable" for all remote deps
- [ ] New integration tests for offline scenarios

### US-504: Dependency Version Constraints (Semver Ranges)
**Description:** As a user, I want to specify version constraints in `pike.json` — like `"dep": "^1.2.0"` or `"dep": ">=1.0.0 <2.0.0"` — instead of pinning to exact tags.

**Current state:** Dependencies are `"name": "source#tag"` where tag is exact. No range resolution, no constraint satisfaction.

**Scope:**
- `pike.json` accepts constraint syntax: `^1.2.0`, `~1.2.0`, `>=1.0.0 <2.0.0`, `1.*`, `*`
- `parse_deps` returns constraint objects alongside source URLs
- `install_one` resolves to the latest tag matching the constraint
- Lockfile records the resolved tag, not the constraint
- `pmp update` respects constraints (won't bump past allowed range)
- `pmp outdated` shows constraint-allowed updates vs lockfile

**Acceptance Criteria:**
- [ ] Design document: `docs/decisions/0005-semver-ranges.md`
- [ ] New `Semver.pmod` functions: `parse_range`, `version_satisfies`
- [ ] `parse_deps` updated to parse constraint syntax
- [ ] `install_one` uses constraint-aware resolution
- [ ] `pike.json` with `"dep": "^1.0.0"` resolves to latest 1.x
- [ ] `pike.json` with `"dep": "~1.2.0"` resolves to latest 1.2.x
- [ ] Backward compatible: exact tags still work (`"dep": "github.com/owner/repo#v1.2.3"`)

---

## Functional Requirements

### Correctness
- FR-1: `pmp update <module>` MUST prune transitive deps no longer required by the updated module
- FR-2: `merge_lock_entries` MUST error on entries with empty names, not silently drop them
- FR-3: `read_lockfile` MUST error on unrecognized lockfile version, not silently parse
- FR-4: `pmp remove` MUST be atomic — partial failure MUST roll back to pre-operation state
- FR-5: `pmp lock` MUST NOT install modules or create symlinks as a side effect
- FR-6: `_read_json_mapping` MUST distinguish "file not found" from "malformed JSON"
- FR-7: `classify_bump` MUST have explicit branches for all version transition types

### Security
- FR-8: SSRF protection MUST correctly block all IPv6 loopback addresses including `::1`
- FR-9: Error messages MUST NOT contain credentials from URLs
- FR-10: `file://` URLs MUST be rejected with a specific error message
- FR-11: Local dependency paths MUST be validated against traversal after resolution

### Architecture
- FR-12: `project_lock`/`project_unlock` MUST live in Helpers.pmod, not Install.pmod
- FR-13: HTTP redirect/SSRF logic MUST NOT be duplicated between `http_get` and `http_get_safe`
- FR-14: Resolve dying/safe variants MUST share URL construction logic
- FR-15: Store orphan detection MUST be shared between `cmd_store prune` and `cmd_verify`

### Documentation
- FR-16: All version numbers in documentation MUST match `Config.PMP_VERSION`
- FR-17: All test counts in documentation MUST match actual pass counts
- FR-18: All module counts and layer descriptions MUST match actual codebase

---

## Non-Goals (Out of Scope)

- **Pike version upgrade** — staying on Pike 8.0
- **Performance optimization** — not a goal of this remediation
- **CI/CD pipeline changes** — existing workflow structure is adequate
- **LSP implementation** — separate project
- **Plugin system** — out of scope for this roadmap
- **Registry server** — pmp resolves from git sources, not a central registry
- **Network-dependent test coverage** — Resolve.pmod and Store.pmod remote operations cannot be tested without mock infrastructure (separate investment)
- **TIGER_STYLE.md full adoption** — Zig-specific patterns are inapplicable to Pike; only the filtered subset in AGENTS.md is adopted

---

## Design Considerations

### Locking architecture (US-401)

Locking primitives should live in the utility layer (Helpers.pmod) alongside `advisory_lock`/`advisory_unlock`. The registration-based cleanup pattern (`register_project_lock_path`, `set_store_lock_state`) already lives in Helpers. Moving `project_lock`/`project_unlock` there completes the picture.

The `store_lock`/`store_unlock` in Store.pmod follow the same pattern and should move to Helpers for consistency. This doesn't change Store.pmod's install logic — it just calls Helpers for locking instead of defining its own.

### Install resolution split (US-204)

Splitting `install_one` into `resolve_one` + `install_one`:
- `resolve_one(source, ctx)` — resolves latest tag, commit SHA, checks store. Returns `mapping` with name, version, sha, store_entry (if exists). Makes network calls if needed.
- `install_one(source, ctx)` — calls `resolve_one`, then downloads/extracts/symlinks if store entry doesn't exist.

This allows `cmd_lock` to call `resolve_one` without side effects, while `cmd_install` calls the full `install_one`.

### HTTP deduplication (US-402)

The duplicated code is:
```
http_get:     _do_get -> check status -> die on error -> follow redirects with SSRF -> die on redirect error
http_get_safe: _do_get -> check status -> return 0 on error -> follow redirects with SSRF -> return 0 on redirect error
```

Unified approach:
```
_do_request(url, opts) -> returns result mapping or 0
http_get(url, opts)     -> result = _do_request(url, opts); if (!result) die(...); return result;
http_get_safe(url, opts) -> return _do_request(url, opts);
```

### Workspace design (US-501)

Following cargo's model:
- Root `pike.json` declares `"workspace": ["packages/*"]`
- Member `pike.json` files are normal manifests
- `pmp install` at root: discover members, parse all deps, resolve, dedup, write shared lockfile
- Workspace members depend on each other via `"./sibling"` — these are local deps resolved by `resolve_local_path`
- Shared store — all members symlink into the same `~/.pike/store/`

### Pike inheritance constraint

Pike's `inherit .Foo` copies state at compile time. Shared mutable state uses `getenv`/`putenv`. Any new module decomposition must follow this pattern. The flat-inherit architecture in `module.pmod` works but creates namespace pressure — 17 modules in one namespace. Feature additions (workspaces, ranges) should be new modules in appropriate layers, not extensions to existing ones.

---

## Technical Considerations

### IPv6 SSRF fix complexity

The `_is_private_host` function is 127 lines of hand-rolled IP checking. The `::` expansion bug (US-301) is subtle — the fix must handle: empty prefix (`::1`), empty suffix (`fe80::`), both empty (`::`). Consider replacing the expansion logic with Pike's `Protocols.IPv6` if available, or add explicit short-circuit checks before expansion.

### Atomic remove implementation

The snapshot-restore pattern for `cmd_remove`:
1. Snapshot symlink target, pike.json content, lockfile content
2. Remove symlink
3. If pike.json edit fails: recreate symlink, die
4. If lockfile write fails: recreate symlink, restore pike.json, die
5. Success: no restore needed

This requires reading all three artifacts before mutating any of them.

### Offline mode audit surface

Every `http_get`, `http_get_safe`, and `Process.run` call site must be audited for offline behavior. Key locations:
- Resolve.pmod: `latest_tag_*`, `resolve_commit_sha` — must check `ctx["offline"]` before network calls
- Store.pmod: `store_install_*` — must check store cache before network
- LockOps.pmod: `cmd_changelog` — must skip or report unavailable

---

## Audit Findings — Verified Status

| ID | Severity | Finding | Status |
|---|---|---|---|
| CORE-01 | HIGH | `::1` SSRF bypass via IPv6 expansion bug | **OPEN** — US-301 |
| CORE-02 | MEDIUM | `_read_json_mapping` silent JSON parse failure | **OPEN** — US-205 |
| CORE-03 | LOW | `die_internal` only 1 callsite — near-dead code | Accept (defensible) |
| CORE-04 | LOW | `find_project_root` doesn't check `/pike.json` | Accept (edge case) |
| CORE-05 | MEDIUM | `atomic_symlink` fails across mount points | Document (known Pike limitation) |
| CMD-01 | HIGH | `pmp update <module>` accumulates stale transitive deps | **OPEN** — US-201 |
| CMD-02 | HIGH | `pmp lock` side-effects installs | **OPEN** — US-204 |
| CMD-03 | MEDIUM | `pmp remove` non-atomic | **OPEN** — US-203 |
| CMD-04 | MEDIUM | Lockfile silent data loss on malformed input | **OPEN** — US-202 |
| CMD-05 | LOW | `cmd_changelog` same-SHA local deps show "no changes" | Accept (edge case) |
| CMD-06 | LOW | `cmd_outdated` no API call caching | Future optimization |
| CMD-07 | MEDIUM | `classify_bump` prerelease logic reached by fallthrough | **OPEN** — US-206 |
| SEC-01 | CRITICAL | SSRF bypass: `::1` not blocked | **OPEN** — US-301 |
| SEC-02 | HIGH | Credential leakage in error URLs | **OPEN** — US-302 |
| SEC-03 | MEDIUM | `file://` URL not explicitly rejected | **OPEN** — US-303 |
| SEC-04 | HIGH | Local dep path traversal after resolution | **OPEN** — US-304 |
| SEC-05 | LOW | DNS rebinding not mitigated | Document (known limitation) |
| SEC-06 | LOW | No proxy auth support | Future enhancement |
| ARCH-01 | MEDIUM | `project_lock` in orchestrator, not utility | **OPEN** — US-401 |
| ARCH-02 | MEDIUM | 60 lines duplicated redirect/SSRF logic | **OPEN** — US-402 |
| ARCH-03 | LOW | 6 near-duplicate resolve dying/safe variants | **OPEN** — US-403 |
| ARCH-04 | LOW | Orphan detection duplicated StoreCmd/Verify | **OPEN** — US-404 |
| ARCH-05 | LOW | `init_std_libs` runs for every command | Future lazy init |
| DOC-01 | MEDIUM | Version 0.3.0 in docs, 0.4.0 in code | **OPEN** — US-101 |
| DOC-02 | LOW | Stale test counts in docs | **OPEN** — US-101 |
| DOC-03 | LOW | TIGER_STYLE.md is verbatim Zig guide | **OPEN** — US-101 |

---

## Implementation Priority

### Phase 1: Truth (1-2 sessions)
Documentation reconciliation only. Zero risk, zero test impact.
**Delivers:** US-101, US-102

### Phase 2: Correctness (3-5 sessions)
Fix bugs that cause silent data loss or wrong state. Each fix gets regression tests.
**Delivers:** US-201, US-202, US-203, US-204, US-205, US-206

### Phase 3: Security (2-3 sessions)
Harden SSRF, credentials, path traversal. Test with adversarial inputs.
**Delivers:** US-301, US-302, US-303, US-304

### Phase 4: Architecture (2-3 sessions)
Extract shared primitives, eliminate duplication. Refactor-only, no behavior changes.
**Delivers:** US-401, US-402, US-403, US-404

### Phase 5: Features (6-10 sessions)
Each feature is a full design-implement-test cycle. Order by dependency:
1. Lockfile v2 (US-502) — needed before workspaces
2. Semver ranges (US-504) — needed for constraint-aware install
3. Offline mode (US-503) — hardens the install path
4. Workspaces (US-501) — largest feature, depends on lockfile v2 + semver ranges

**Delivers:** US-501, US-502, US-503, US-504

---

## Open Questions

1. **Lockfile rename**: Should `pike.lock` become `pmp.lock`? Breaking change for existing projects. Option: write `pmp.lock`, create `pike.lock` symlink, deprecation period.
2. **Workspace member `pike.json`**: Should workspace members use a different manifest file (like cargo's `Cargo.toml` vs workspace root)? Or same `pike.json` with added `"workspace-members"` key?
3. **Semver range syntax**: Follow npm (`^`, `~`, `>=`), cargo (`"1.2.0"` = `^1.2.0`), or something else? Cargo's implicit caret is elegant but surprising.
4. **SHA prefix length**: Current 8-char prefix for store entries. At 8 hex chars (32 bits), collision probability is ~0.1% at 10K entries (birthday bound). Increase to 16? This is a format change that affects store layout.
5. **Thread leak on HTTP timeout**: Pike cannot cancel threads. Current behavior leaks the thread. Options: accept the leak (bounded by process lifetime), switch to non-blocking I/O, or use `Process.popen` instead of threaded HTTP. This affects all HTTP operations.
6. **`TMPDIR` cross-mount `atomic_symlink`**: If `TMPDIR` is a tmpfs (common on Linux), `atomic_symlink` will fail for disk-backed stores. Should `make_temp_dir` use the store directory as temp parent instead of `$TMPDIR`?

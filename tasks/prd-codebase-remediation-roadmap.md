# PRD: PMP Codebase Remediation Roadmap

## Introduction

A full-spectrum audit of the pmp codebase reveals three categories of problems: (1) **brittle/failing patterns** that work under normal conditions but break under adversarial or edge-case inputs, (2) **implemented-but-disconnected code** that exists on disk but is not wired into the system, and (3) **LLM-generated artifacts** that were plausible at generation time but are inconsistent with reality — wrong module counts, phantom integration claims, and documentation that contradicts the source.

This PRD provides a prioritized roadmap to bring the codebase to a coherent, honest state where documentation matches implementation, dead code is either wired in or removed, and known fragilities are hardened.

**Test baseline (verified 2026-04-30):** 172 shell tests pass, 373 Pike unit tests pass, 0 failures.

## Goals

1. Every module listed in documentation exists in code; every module in code is listed in documentation.
2. Cache.pmod is either wired into Http.pmod (its intended consumer) or removed.
3. Verify.pmod is documented in README.md and ARCHITECTURE.md alongside its commands (`verify`, `doctor`).
4. Semver.pmod rejects all spec-violating inputs (the 6 CRITICAL findings S-01 through S-06).
5. Install.pmod is decomposed from a 1043-line God module into focused sub-modules.
6. All documentation claims (test counts, module lists, line counts) are accurate and kept in sync.
7. Stale test artifacts are cleaned up and tests are hardened against leakage.
8. The codebase tells the truth about what it is — no phantom features, no outdated claims.

## User Stories

### US-001: Reconcile documentation with reality
**Description:** As a developer, I want all documentation files (AGENTS.md, ARCHITECTURE.md, README.md, CHANGELOG.md) to accurately reflect the actual codebase so I'm not misled when onboarding or debugging.

**Acceptance Criteria:**
- [ ] AGENTS.md lists all 16 functional modules (Config, Helpers, Source, Http, Resolve, Store, Lockfile, Manifest, Validate, Semver, Install, StoreCmd, Project, Env, Verify, Cache) plus module.pmod
- [ ] ARCHITECTURE.md lists all 16 functional modules with accurate descriptions
- [ ] README.md includes `verify` and `doctor` in the command list
- [ ] Test counts in AGENTS.md match reality: "172 shell tests + 373 Pike unit tests"
- [ ] pmp.pike line count claims match actual (~252 lines, not ~185 or ~190)
- [ ] No document claims "14 modules" or "15 sub-modules" — the real count is 16 functional + 1 aggregator = 17 .pmod files
- [ ] CHANGELOG.md [Unreleased] section lists documentation reconciliation

### US-002: Resolve Cache.pmod — wire in or remove
**Description:** As a developer, I want Cache.pmod to either be part of the system (inherited in module.pmod, called by Http.pmod) or removed entirely, so there is no orphaned code.

**Acceptance Criteria:**
- [ ] Decision documented in an ADR (`docs/decisions/0002-cache-strategy.md`)
- [ ] If wired in: module.pmod inherits .Cache, Http.http_get checks cache before network, cache_prune is called during store prune
- [ ] If removed: Cache.pmod deleted, CacheAdversarialTests.pike deleted, module.pmod unchanged, no references remain
- [ ] All tests pass after the change
- [ ] AGENTS.md and ARCHITECTURE.md updated to match the decision

### US-003: Harden Semver.pmod against spec violations
**Description:** As a developer, I want Semver.pmod to correctly reject all inputs that violate Semver 2.0.0 so that version resolution is reliable and predictable.

**Acceptance Criteria:**
- [ ] S-01: Leading zeros in numeric prerelease identifiers (e.g., `1.0.0-01`) are rejected — return 0
- [ ] S-02: Empty prerelease after dash (e.g., `1.0.0-`) is rejected — already fixed, verify test exists
- [ ] S-03: Partial versions (e.g., `1.2`, `1`) are rejected — already fixed (strict 3-part check), verify
- [ ] S-04: Invalid characters in identifiers (e.g., `1.0.0-alpha@beta`) are rejected — verify RE_IDENT coverage
- [ ] S-05: Build metadata identifiers validated (e.g., `1.0.0+`, `1.0.0+.beta`) — verify
- [ ] S-06: Leading zeros in numeric build metadata (currently allowed by semver spec — clarify decision)
- [ ] All 51 Semver Pike tests pass
- [ ] New adversarial tests added for any fixed violations
- [ ] CHANGELOG.md updated

### US-004: Decompose Install.pmod God module
**Description:** As a developer, I want Install.pmod split into focused modules so that install logic, update logic, lock/rollback logic, and changelog logic are independently testable and maintainable.

**Acceptance Criteria:**
- [ ] Install.pmod contains only install_one, cmd_install, cmd_install_all, cmd_install_source (< 400 lines)
- [ ] New Update.pmod contains cmd_update, cmd_outdated, print_update_summary
- [ ] New LockOps.pmod contains cmd_lock, cmd_rollback, cmd_changelog
- [ ] module.pmod inherits the new modules
- [ ] pmp.pike dispatch table updated if needed
- [ ] All 172 shell tests + 373 Pike tests pass
- [ ] AGENTS.md, ARCHITECTURE.md updated with new module structure
- [ ] No circular dependencies introduced

### US-005: Fix known audit findings still open
**Description:** As a developer, I want the remaining CRITICAL and HIGH audit findings from AUDIT_CONSOLIDATED.md addressed so the codebase is production-ready.

**Acceptance Criteria:**
- [ ] C-05: Credential leakage in error messages — URLs in die/warn messages show only host+path, never credentials
- [ ] C-07: file:// URLs are handled — either supported with validation or explicitly rejected with clear error
- [ ] C-10: SHA truncation to 8 chars reviewed — document decision: current 8-char prefix is sufficient for collision resistance within the store namespace, or increase to 16
- [ ] C-17: cmd_update deadlock on project_lock — verify lock acquisition ordering is consistent
- [ ] P-01: cmd_remove atomicity — three-step operation (symlink + pike.json + lockfile) is atomic or has rollback
- [ ] H-28: Lockfile write failure after module install — modules rolled back on lockfile write failure
- [ ] H-29: cmd_rollback acquires project lock
- [ ] Each fix has a corresponding test
- [ ] CHANGELOG.md updated

### US-006: Clean up stale test artifacts and harden test isolation
**Description:** As a developer, I want test runs to clean up after themselves and not leak state between test files.

**Acceptance Criteria:**
- [ ] All ~60 `.tmp-manifest-test-*` files deleted from repo root
- [ ] `.tmp-test-lockfile-io-*` directories deleted from repo root
- [ ] `.gitignore` updated to exclude `.tmp-*-test-*` patterns
- [ ] Manifest test cleanup uses trap or finally pattern so temp files are removed even on test failure
- [ ] Shell test runner (runner.sh) resets CWD between test files
- [ ] No test relies on state left by a previous test file
- [ ] All 172 shell tests + 373 Pike tests pass after cleanup

### US-007: Deduplicate Pike test suites
**Description:** As a developer, I want the Pike test suites to have clear ownership so that merge_lock_entries, classify_bump, and lockfile_add_entry are tested in one canonical location.

**Acceptance Criteria:**
- [ ] merge_lock_entries tested in LockfileAdversarialTests.pike only (remove duplicates from InstallAdversarialTests, LockfilePureTests)
- [ ] lockfile_add_entry tested in LockfileAdversarialTests.pike only
- [ ] classify_bump tested in SemverAdversarialTests.pike only (remove duplicates from InstallAdversarialTests, ResolveAdversarialTests)
- [ ] compute_sha256 tested in HelpersAdversarialTests.pike only (remove HelpersTests.pike or merge)
- [ ] SourceTests.pike merged into SourceAdversarialTests.pike (or vice versa)
- [ ] All 373+ Pike tests pass after dedup
- [ ] Test count updated in AGENTS.md

### US-008: Add missing test coverage for untested modules
**Description:** As a developer, I want StoreCmd.pmod and the pmp.pike CLI entry point to have test coverage so regressions are caught.

**Acceptance Criteria:**
- [ ] New tests/pike/StoreCmdAdversarialTests.pike covering cmd_store, dir_size, human_size, _entry_referenced
- [ ] New tests/test_35_store_prune.sh testing `pmp store prune --force` with referenced/unreferenced entries
- [ ] New shell tests for verify/doctor commands (currently test_28 and test_31 exist — verify they cover the full surface)
- [ ] All new tests pass
- [ ] Test counts updated in AGENTS.md

## Functional Requirements

- FR-1: All documentation files MUST accurately list all 16 functional modules and 1 aggregator module
- FR-2: Cache.pmod MUST either be inherited in module.pmod and used by Http.pmod, OR deleted entirely with its test suite
- FR-3: Semver.parse_semver MUST reject all Semver 2.0.0 spec violations (leading zeros, empty identifiers, partial versions, invalid characters)
- FR-4: Install.pmod MUST be decomposed into modules with clear single responsibilities (install, update, lock/rollback)
- FR-5: Error messages MUST NOT leak credentials (tokens, passwords in URLs)
- FR-6: file:// URLs MUST be explicitly handled (supported or rejected with clear message)
- FR-7: cmd_remove MUST be atomic — failure mid-operation MUST roll back partial state
- FR-8: cmd_rollback MUST acquire the project lock
- FR-9: Test runs MUST clean up temp files and directories, even on failure
- FR-10: Shell test runner MUST reset CWD between test files
- FR-11: Duplicate test coverage across Pike test suites MUST be eliminated
- FR-12: StoreCmd.pmod MUST have Pike unit test coverage
- FR-13: All documentation test count claims MUST match actual pass counts
- FR-14: No stale test artifact files (.tmp-*-test-*) MUST exist in the repository root
- FR-15: README.md MUST list all available commands including `verify` and `doctor`

## Non-Goals (Out of Scope)

- **LSP implementation** — this audit predates any LSP work; the LSP is a separate project
- **Performance optimization** — not a goal of this remediation
- **New features** — no new commands, no new source types, no new flags
- **CI/CD pipeline changes** — existing workflow structure is adequate
- **Pike version upgrade** — staying on Pike 8.0
- **Network-dependent test coverage** — Resolve.pmod and Store.pmod remote operations cannot be tested without mock infrastructure, which is a separate investment
- **Config.pmod lock constants** (LOCK_MAX_ATTEMPTS_STORE etc.) — the TODO in ConfigTests.pike can remain; these are aspirational constants not yet needed by the implementation

## Design Considerations

### Module decomposition strategy (US-004)

Install.pmod currently inherits 10 other modules. When splitting:
- `Update.pmod` should inherit .Config, .Helpers, .Source, .Http, .Resolve, .Store, .Lockfile, .Semver
- `LockOps.pmod` should inherit .Helpers, .Lockfile, .Http, .Resolve
- `Install.pmod` should inherit .Config, .Helpers, .Source, .Http, .Resolve, .Store, .Lockfile, .Manifest, .Semver, .Validate
- Shared helpers (`get_resolved_sha`, `_move_contents`, `project_lock`/`project_unlock`) should live in Install.pmod or a new shared InstallHelpers.pmod

### Cache.pmod decision framework (US-002)

Arguments for wiring in:
- 140 lines of working code with ETag/Last-Modified support
- Already has 18 comprehensive tests
- Would reduce API calls to GitHub/GitLab during resolve operations

Arguments for removing:
- Never been wired in — no production usage data
- Adds filesystem state (cache invalidation complexity)
- Http.pmod already has retry logic; caching is a separate concern
- If needed later, can be re-implemented with better integration

### Test isolation pattern (US-006)

The shell test framework shares a single process. Options:
- A) Add `cd "$ORIG_DIR"` between test file sourcing in runner.sh
- B) Require each test file to manage its own CWD
- C) Run each test file in a subshell (breaks counter sharing)

Recommendation: A — minimal change, fixes the problem.

## Technical Considerations

### Pike inheritance gotcha

Pike's `inherit .Foo` copies module state at compile time. This is why shared mutable state uses `getenv`/`putenv`. Any new module decomposition must follow this pattern — no new mutable globals.

### Install.pmod dependency chain

Install.pmod's 10-way inherit creates a deep dependency tree. After decomposition, ensure no circular inherits. The dependency graph is:

```
Config ← (standalone)
Helpers ← Config
Semver ← (standalone)
Source ← Helpers
Http ← Helpers
Resolve ← Helpers, Http, Semver
Store ← Helpers, Http, Resolve
Lockfile ← Helpers
Manifest ← Helpers
Validate ← Helpers, Manifest
Cache ← Helpers, Config
Verify ← Helpers, Source, Store, Lockfile
```

Any new modules must fit cleanly into this DAG.

### Test count tracking

Current actual counts (2026-04-30):
- Shell: 172 passed (34 files)
- Pike: 373 passed (21 test suites)
- Total: 545 test assertions

The `--frozen-lockfile` and `--offline` flags in test_29 are integration-level tests that depend on the store being populated by earlier tests — these must run in order.

## Audit Findings Status Summary

| ID | Severity | Finding | Status |
|---|---|---|---|
| C-01 | CRITICAL | run_cleanup dead code | Fixed (wired into signal handlers + die) |
| C-02 | CRITICAL | non-atomic fallback in atomic_write | Fixed (uses Pike mv()) |
| C-03 | CRITICAL | Cache.pmod dead code | **OPEN** — US-002 |
| C-04 | CRITICAL | HTTP response truncation | Fixed (body size limit) |
| C-05 | CRITICAL | Credential leakage | **OPEN** — US-005 |
| C-06 | CRITICAL | SSRF via private IPs | Partially fixed (redirect protection) |
| C-07 | CRITICAL | file:// URL handling | **OPEN** — US-005 |
| C-08 | CRITICAL | Tarball extraction | Fixed (hardened) |
| C-10 | CRITICAL | SHA truncation collisions | **OPEN** — US-005 |
| C-17 | CRITICAL | cmd_update deadlock | **OPEN** — US-005 |
| C-18 | CRITICAL | install.sh POSIX | Fixed |
| S-01 | CRITICAL | Semver leading zeros | **VERIFY** — US-003 |
| S-02 | CRITICAL | Semver empty prerelease | Fixed — US-003 verifies |
| S-03 | CRITICAL | Semver partial versions | Fixed — US-003 verifies |
| S-04 | CRITICAL | Semver invalid identifiers | **VERIFY** — US-003 |
| S-05 | CRITICAL | Semver build metadata | Fixed — US-003 verifies |
| S-06 | CRITICAL | Semver prerelease numeric leading zeros | **VERIFY** — US-003 |
| P-01 | HIGH | cmd_remove non-atomic | **OPEN** — US-005 |
| P-02 | HIGH | cmd_remove unconditional lockfile rewrite | **OPEN** — US-005 |
| P-03 | HIGH | cmd_clean count mismatch | Low impact |
| H-28 | HIGH | Lockfile write failure after install | **OPEN** — US-005 |
| H-29 | HIGH | cmd_rollback no lock | **OPEN** — US-005 |
| H-31 | HIGH | Store prune deletes referenced by broken symlink | Low priority |
| X-01 | MEDIUM | BEHAVIOR_SPEC contradicts code | **OPEN** — US-001 (docs reconciliation) |

## Implementation Priority (Phases)

### Phase 1: Truth — Documentation and cleanup (US-001, US-006)
No code behavior changes. Pure documentation reconciliation and artifact cleanup. Zero risk.

### Phase 2: Decide — Cache.pmod resolution (US-002)
Either wire in or delete. One ADR, one direction. Low risk either way.

### Phase 3: Harden — Security and correctness fixes (US-003, US-005)
Semver hardening, credential leak fixes, atomicity fixes. These fix real bugs.

### Phase 4: Structure — Module decomposition (US-004)
Split Install.pmod. Largest change, most risk. Do after Phase 3 hardening so the split operates on already-correct code.

### Phase 5: Coverage — Test dedup and new tests (US-007, US-008)
Consolidate existing tests, add missing coverage. Final validation of all prior phases.

## Open Questions

1. **Cache.pmod direction** — Wire in or remove? This is a product decision with tradeoffs (see Design Considerations).
2. **SHA prefix length** — Is 8 chars sufficient for the store namespace? At 16 hex chars (64 bits), collision probability is negligible. At 8 chars (32 bits), it's still very low for typical store sizes (<10K entries) but theoretically possible. Should we increase?
3. **file:// URL support** — Should pmp support `file://` URLs as a source type? Currently unhandled. Either explicitly reject with error message or implement with validation.
4. **SSRF private IP blocklist** — The redirect protection exists but there's no private IP blocklist for initial requests. Should `_is_private_host` be enforced on all outgoing requests, not just redirects?
5. **Install.pmod split naming** — `LockOps.pmod` for lock/rollback/changelog? `Update.pmod` for update/outdated? Or different names?

# PRD: pmp 1.0.0 Roadmap — Production-Grade Package Manager

## Introduction

pmp is a Pike module package manager inspired by bun, uv, and cargo. It installs, versions, and resolves dependencies for Pike modules across GitHub, GitLab, self-hosted git, and local paths. The codebase currently sits at v0.4.0 with 4,672 lines across 18 source files, 208 shell tests, and 330 Pike unit tests — all green.

A full audit reveals: the core is solid (content-addressable store, atomic I/O, SSRF protection, tar extraction hardening), but there are real bugs, documentation drift, hallucinated features in docs, missing test coverage for critical paths, and significant feature gaps versus the bun/uv/cargo patterns pmp takes inspiration from.

This PRD defines a phased roadmap to bring pmp to 1.0.0: production-grade, well-tested, well-documented, and feature-complete for a real ecosystem.

---

## Goals

1. Fix every known bug and documentation inconsistency
2. Close test coverage gaps for all critical paths
3. Deliver the already-decided ADRs (lockfile v2, semver ranges, workspaces, HTTP caching)
4. Adopt the highest-impact patterns from bun/uv/cargo
5. Ship 1.0.0 with confidence that every feature is verified

## Non-Goals

- Rewriting pmp in a different language (Pike is the ecosystem)
- SAT solver / full PubGrub resolver (overkill at Pike ecosystem scale)
- Package registry server (pmp resolves from git tags)
- IDE integration or LSP for pmp
- Binary platform-specific I/O (hardlinks/clonefile — Pike runtime limitation)

---

## Audit Findings Summary

### Bugs Found

| ID | Severity | Location | Description |
|----|----------|----------|-------------|
| BUG-01 | Medium | `bin/Pmp.pmod/Http.pmod:500,522` | User-Agent hardcoded to `0.2.0` instead of using `PMP_VERSION` (0.4.0). API calls misidentify the client version. |
| BUG-02 | Low | `bin/Pmp.pmod/Store.pmod` | Duplicate doc comment on `extract_targz` — consecutive identical `//!` blocks. |
| BUG-03 | Low | `tests/pike/InstallAdversarialTests.pike` | File named for `Install` but only tests `Update.print_update_summary`. Misleading name. |

### Documentation Drift (30 Issues)

| Category | Count | Key Examples |
|----------|-------|--------------|
| Hallucinated features | 6 | SKILL.md lists functions in wrong modules (pre-refactor structure); docs/behavior-spec.md describes layered subdirectory layout that was reverted |
| Stale references | 6 | CHANGELOG.md claims "17 modules across 5 layers" — code is flat; "sha_prefix_8" in docs but code uses 16 chars |
| Cross-doc inconsistencies | 5 | AGENTS.md says 208+330 tests, SKILL.md says 114+81; CONTRIBUTING.md missing `validate` scope |
| Wrong line/char counts | 4 | SKILL.md says ~185-line entry point (actual: 274 lines); module count wrong (says 15, actual 17) |
| Outdated test counts | 3 | SKILL.md not updated after test suite expansion |
| Missing features in docs | 2 | SKILL.md omits Verify.pmod, Update.pmod, LockOps.pmod entirely |
| Version inconsistencies | 2 | Http.pmod user-agent 0.2.0 vs Config.PMP_VERSION 0.4.0; README pin example shows v0.3.0 |

### Test Coverage Gaps

| Area | What's Missing |
|------|----------------|
| LockOps.pmod | Zero dedicated Pike tests. Only shell coverage via test_20, test_21 |
| Update.pmod `cmd_update` | Only shell test_22. No Pike unit tests for update logic. |
| Update.pmod `cmd_outdated` | test_27 only tests error cases (no pike.json, empty deps). No test for actual remote version comparison. |
| Http.pmod `http_get`/`http_get_safe` | No direct test. Only helper function tests (_url_host, _redirect, _is_private_host). Core HTTP path untested. |
| Store.pmod `write_meta` | No direct test. Only `read_stored_hash` tested. |
| Store.pmod `store_install_*` | No Pike tests (would require network). Only exercised via shell integration with local deps. |
| Helpers.pmod `need_cmd`, `die_internal`, `warn`, `debug`, `info` | No direct tests. |
| Install.pmod `install_one`, `cmd_install_all` | No Pike unit tests. Only shell integration. |
| Semver.pmod `compare_prerelease` | Public API per behavior-spec but zero direct tests. |
| Self-update (git fetch+checkout) | test_25 only checks exit code and output. Core logic (tag checkout) untested. |

### Brittleness & Failure Modes

| Area | Risk | Description |
|------|------|-------------|
| Broad catch blocks | 30+ catch-all `catch { }` blocks | Many catch `mixed err` without inspecting the error. Failures produce generic messages that hide root cause. Most are acceptable (top-level catch, rollback paths) but some swallow useful diagnostics. |
| `install_one` at 140 lines | Maintainability | Single function handles local + github + gitlab + selfhosted with branching logic. Hard to test individual paths. |
| `cmd_install_all` at 160 lines | Maintainability | Lockfile replay + staging + atomic swap in one function. Complex state management. |
| `_is_private_host` at 115 lines | Complexity | Single SSRF checker handles IPv4, IPv6, mapped addresses, octal/hex parsing, CIDR ranges. Well-tested but dense. |
| `cmd_remove` at 100 lines | Rollback safety | Validation + execution + rollback in one function with nested catch blocks. |
| No HTTP caching | Performance | Every `pmp install` fetches fresh metadata from GitHub/GitLab APIs. No ETag, no Last-Modified, no conditional requests. ADR-0002 removed the orphaned Cache.pmod. |
| Single-threaded | Performance | Pike is single-threaded. No parallel downloads, no metadata prefetching during resolution. Acceptable for ecosystem size but limits scalability. |
| `pike.lock` format is flat TSV | Extensibility | 5 tab-separated fields, no nesting for transitive deps, no whole-file integrity check. Lockfile v2 (ADR-0003) addresses this. |

### Hallucinated / Ghost Features

These are features that appear in documentation but don't exist in code, or exist in code but are documented as something else:

1. **Layered directory layout** (docs/behavior-spec.md, CHANGELOG.md): Docs describe `core/`, `transport/`, `store/`, `project/`, `commands/` subdirectories. Code is flat. The layered layout was attempted and reverted.
2. **SKILL.md module list**: Still describes pre-refactor structure where Install.pmod contains `cmd_update`, `cmd_lock`, etc. These were extracted to Update.pmod and LockOps.pmod.
3. **SKILL.md omits 3 modules**: Verify.pmod, Update.pmod, LockOps.pmod are not mentioned at all.
4. **`gitlab_auth_headers`**: Listed in behavior-spec.md but untested in HttpAdversarialTests.pike (only github_auth_headers tested).
5. **`compare_prerelease` as public API**: Documented in behavior-spec.md but has zero direct tests.

---

## Roadmap

### Phase 0: Housekeeping (v0.4.x)

**Goal**: Fix every known bug, eliminate doc drift, close the worst test gaps. Zero regressions. Every file tells the truth.

#### US-001: Fix Http.pmod user-agent version
**Description:** As a developer, I want the HTTP User-Agent to report the correct version so API servers see accurate client identification.

**Acceptance Criteria:**
- [ ] `http_get` and `http_get_safe` use `PMP_VERSION` from Config.pmod instead of hardcoded `"0.2.0"`
- [ ] Grep confirms zero remaining hardcoded version strings in Http.pmod
- [ ] All 208 shell tests pass
- [ ] All 330 Pike tests pass

#### US-002: Fix duplicate doc comment in Store.pmod
**Description:** As a developer, I want clean source files without duplicate documentation.

**Acceptance Criteria:**
- [ ] Remove duplicate `//!` block on `extract_targz` in Store.pmod
- [ ] All tests pass

#### US-003: Rename InstallAdversarialTests.pike
**Description:** As a developer, I want test file names to accurately reflect what they test.

**Acceptance Criteria:**
- [ ] Rename `tests/pike/InstallAdversarialTests.pike` to `tests/pike/UpdateAdversarialTests.pike`
- [ ] Update class name inside the file
- [ ] Update imports to reference `Pmp.Update`
- [ ] All 330 Pike tests pass

#### US-004: Reconcile all documentation with actual codebase
**Description:** As a developer, I want every doc file to accurately describe the current code, with no hallucinated features, no stale references, and consistent test counts.

**Acceptance Criteria:**
- [ ] AGENTS.md: Fix `sha_prefix_8` to `sha_prefix16`; update line counts; update module list to all 17+1
- [ ] ARCHITECTURE.md: Fix test count from 172 to 208; verify all module descriptions match current code
- [ ] SKILL.md: Update module list to include all 17 modules (add Verify, Update, LockOps); fix line counts; fix function-to-module mappings; update test counts to 208+330
- [ ] CONTRIBUTING.md: Add `validate` to scope list
- [ ] docs/behavior-spec.md: Remove layered directory layout description; describe flat layout; fix sha_prefix_8 references
- [ ] CHANGELOG.md: Fix "5 layers" references; add note that layered layout was reverted
- [ ] README.md: Update version pin example to v0.4.0
- [ ] No doc references non-existent subdirectories under bin/Pmp.pmod/
- [ ] All test counts across docs agree: 208 shell, 330 Pike

#### US-005: Add Pike unit tests for LockOps.pmod
**Description:** As a developer, I want unit tests for lock/rollback/changelog commands that currently have zero dedicated Pike tests.

**Acceptance Criteria:**
- [ ] Create `tests/pike/LockOpsAdversarialTests.pike` with tests for:
  - `cmd_lock` with valid project
  - `cmd_lock` without pike.json (error path)
  - `cmd_rollback` with valid pike.lock.prev
  - `cmd_rollback` without pike.lock.prev (error path)
  - `cmd_changelog` with version diff
- [ ] All existing + new tests pass

#### US-006: Add Pike unit tests for Update.pmod cmd_update
**Description:** As a developer, I want unit tests covering the update logic beyond what print_update_summary tests.

**Acceptance Criteria:**
- [ ] Add tests to UpdateAdversarialTests.pike for:
  - `cmd_update` argument parsing (module name extraction)
  - `cmd_outdated` with mock lockfile data
- [ ] All tests pass

---

### Phase 1: Lockfile v2 (v0.5.0) — Already Decided (ADR-0003)

**Goal**: Upgrade the lockfile format to support integrity verification, whole-file checksums, and extensibility for future features.

#### US-007: Implement lockfile v2 format
**Description:** As a user, I want a lockfile with integrity guarantees so I can trust my builds are reproducible.

**Acceptance Criteria:**
- [ ] New format: header line `pmp-lockfile-v2`, per-entry integrity field (content_sha256), whole-file checksum footer
- [ ] Backward-compatible read: pmp reads v1 lockfiles and migrates automatically
- [ ] `write_lockfile` produces v2 format
- [ ] `read_lockfile` handles both v1 and v2
- [ ] `pike.lock` renamed to `pmp.lock` (with migration)
- [ ] Update Lockfile.pmod, LockOps.pmod, Install.pmod
- [ ] Update all shell tests that reference pike.lock
- [ ] Add Pike tests: v1→v2 migration, roundtrip, integrity verification, tampered footer detection
- [ ] All tests pass

---

### Phase 2: HTTP Caching (v0.5.x) — Already Decided (ADR-0002)

**Goal**: Eliminate redundant network requests. Second `pmp install` of the same package should be near-instant.

#### US-008: Implement HTTP caching in Http.pmod
**Description:** As a user, I want repeated installs to be fast by reusing cached metadata, so I'm not waiting on network for unchanged packages.

**Acceptance Criteria:**
- [ ] Cache directory at `~/.pike/cache/http/`
- [ ] Store ETag and Last-Modified headers alongside cached responses
- [ ] `http_get` sends conditional requests (If-None-Match, If-Modified-Since)
- [ ] 304 responses return cached body without re-download
- [ ] Cache entries keyed by URL
- [ ] `--offline` mode reads from cache only
- [ ] `pmp store prune` also prunes stale cache entries
- [ ] Add Pike tests: cache hit, cache miss, cache invalidation, offline from cache
- [ ] All tests pass

---

### Phase 3: Semver Range Constraints (v0.6.0) — Already Decided (ADR-0004)

**Goal**: Support dependency version constraints instead of exact pins.

#### US-009: Implement semver range parsing and resolution
**Description:** As a user, I want to declare dependencies like `"^1.2.0"` or `">=1.0.0 <2.0.0"` so I get compatible updates without manual pin updates.

**Acceptance Criteria:**
- [ ] Add range syntax to Semver.pmod: `^`, `~`, `>=`, `<=`, `>`, `<`, exact, `*`
- [ ] `parse_range(string)` returns a constraint object
- [ ] `satisfies(version, range)` checks if a version matches a constraint
- [ ] `resolve_version(tags, range)` picks highest matching tag
- [ ] pike.json supports range values: `"my-dep": "^1.2.0"` or `"my-dep": {"source": "...", "version": "^1.2.0"}`
- [ ] `install_one` uses range resolution when constraint provided
- [ ] Lockfile records resolved exact version (not range)
- [ ] `pmp update` respects constraints
- [ ] Add comprehensive Pike tests: caret, tilde, gt, lt, gte, lte, wildcard, compound ranges
- [ ] Update Source.pmod `source_to_version` to extract range
- [ ] All tests pass

---

### Phase 4: Dependency Tree & Verify Hardening (v0.7.0)

**Goal**: Make dependency graphs visible and verifiable. Close the biggest test coverage gaps.

#### US-010: Implement `pmp tree` command
**Description:** As a user, I want to see my full dependency graph so I can understand what's installed and why.

**Acceptance Criteria:**
- [ ] New command `pmp tree` reads pmp.lock and displays dependency tree
- [ ] Shows transitive dependencies indented under their parent
- [ ] `--depth N` flag limits tree depth
- [ ] Handles cycles gracefully (shows `[circular]` marker)
- [ ] Requires lockfile — errors if pmp.lock missing
- [ ] New module `Tree.pmod` under `bin/Pmp.pmod/`
- [ ] Add to dispatch in `pmp.pike`
- [ ] Add to help text
- [ ] Add shell tests for tree output format
- [ ] Add Pike tests for tree building logic
- [ ] All tests pass

#### US-011: Implement `pmp vendor` command
**Description:** As a user in an air-gapped environment, I want to download all dependencies for offline auditing and installation.

**Acceptance Criteria:**
- [ ] New command `pmp vendor` downloads all lockfile deps to `./vendor/` directory
- [ ] Creates `./vendor/pmp.lock` snapshot
- [ ] `pmp install --offline` falls back to `./vendor/` when store entries missing
- [ ] `pmp verify --vendor` checks vendor directory integrity
- [ ] New module `Vendor.pmod` under `bin/Pmp.pmod/`
- [ ] Add to dispatch and help text
- [ ] Add shell tests
- [ ] All tests pass

#### US-012: Add HTTP integration tests
**Description:** As a developer, I want tests for the actual HTTP request/response path, not just helper functions.

**Acceptance Criteria:**
- [ ] Create `tests/pike/HttpIntegrationTests.pike`
- [ ] Test `http_get` against a local HTTP server mock (Pike `Protocols.HTTP.Server`)
- [ ] Test retry logic with simulated failures
- [ ] Test redirect following (3xx responses)
- [ ] Test body size limit enforcement
- [ ] Test timeout behavior
- [ ] All tests pass

#### US-013: Harden install_one and cmd_install_all
**Description:** As a developer, I want the install orchestrators refactored for testability.

**Acceptance Criteria:**
- [ ] Extract per-source install logic from `install_one` into dedicated functions: `_install_local`, `_install_github`, `_install_gitlab`, `_install_selfhosted`
- [ ] Extract staging and swap logic from `cmd_install_all` into `_stage_modules` and `_commit_staging`
- [ ] Original functions delegate to extracted helpers
- [ ] No behavioral change — all 208 shell tests pass unchanged
- [ ] All 330 Pike tests pass
- [ ] Each extracted function has Pike unit tests

---

### Phase 5: Environment & Run Hardening (v0.8.0)

**Goal**: Make `pmp run` the canonical entry point (like `uv run`). Ensure environments are always in sync.

#### US-014: Auto lock+sync before `pmp run`
**Description:** As a user, I want `pmp run` to automatically ensure my environment matches pmp.lock, so I never run code against stale dependencies.

**Acceptance Criteria:**
- [ ] `pmp run` checks if pmp.lock is stale vs pike.json before executing
- [ ] If stale, prints warning and runs `pmp install` automatically (unless `--frozen-lockfile`)
- [ ] If lockfile missing, errors with actionable message
- [ ] `--no-sync` flag to skip auto-sync (for speed in tight loops)
- [ ] All tests pass

#### US-015: Exact environment sync
**Description:** As a user, I want `pmp install` to remove modules not in the lockfile, so my environment exactly matches what's declared.

**Acceptance Criteria:**
- [ ] After install, compare `./modules/` symlinks against lockfile entries
- [ ] Remove symlinks not present in lockfile
- [ ] Print summary: "added X, removed Y, unchanged Z"
- [ ] `--no-prune` flag to skip removal
- [ ] Update `prune_stale_deps` in Lockfile.pmod
- [ ] Add shell tests: stale module removal, --no-prune skips removal
- [ ] All tests pass

#### US-016: `pmp run --with <dep>` ephemeral dependencies
**Description:** As a user, I want to run a script with an additional dependency without modifying pike.json, like `uv run --with`.

**Acceptance Criteria:**
- [ ] `pmp run --with github.com/user/pkg script.pike` installs pkg temporarily
- [ ] Dependency available via PIKE_MODULE_PATH for that run only
- [ ] Does not modify pike.json or pmp.lock
- [ ] Does not persist in ./modules/
- [ ] Multiple `--with` flags supported
- [ ] Add shell tests
- [ ] All tests pass

---

### Phase 6: Workspaces (v0.9.0) — Already Decided (ADR-0005)

**Goal**: Support monorepo-style projects with shared dependencies.

#### US-017: Implement workspace support
**Description:** As a user, I want to manage multiple Pike packages in a single repository with shared dependencies and a single lockfile.

**Acceptance Criteria:**
- [ ] Root `pike.json` supports `"workspace": ["packages/*"]` or explicit member list
- [ ] Single `pmp.lock` at workspace root
- [ ] `pmp install` from root installs all workspace members' deps
- [ ] `--package <name>` flag targets specific workspace member
- [ ] Workspace members can depend on each other via `"workspace: true"` or path reference
- [ ] `pmp list --workspace` shows all members
- [ ] `pmp run --package <name>` runs in member context
- [ ] New module `Workspace.pmod` under `bin/Pmp.pmod/`
- [ ] Comprehensive shell tests for workspace operations
- [ ] All tests pass

---

### Phase 7: 1.0.0 Polish

**Goal**: Final hardening, performance validation, documentation completeness. Ship with confidence.

#### US-018: Broad catch block audit
**Description:** As a developer, I want every `catch { }` block to preserve diagnostic information instead of swallowing errors silently.

**Acceptance Criteria:**
- [ ] Audit all 30+ broad catch blocks
- [ ] Each catch either: (a) inspects the error and includes it in the message, (b) is a top-level catch that already reports, or (c) is in a rollback path where the original error is already reported
- [ ] No catch block silently discards error information that would help debugging
- [ ] All tests pass

#### US-019: Performance benchmarking
**Description:** As a developer, I want baseline performance numbers so we can detect regressions.

**Acceptance Criteria:**
- [ ] Create `benchmarks/` directory with repeatable scenarios
- [ ] Benchmark: cold install (no cache), warm install (from store), lockfile reinstall, `pmp run` overhead
- [ ] Document baseline numbers in `docs/performance.md`
- [ ] CI job runs benchmarks and fails on >20% regression
- [ ] Target: lockfile reinstall < 500ms for 10 dependencies

#### US-020: Final documentation pass
**Description:** As a user, I want comprehensive, accurate documentation for the 1.0.0 release.

**Acceptance Criteria:**
- [ ] README.md covers all commands with examples
- [ ] ARCHITECTURE.md reflects final module layout (17+ modules)
- [ ] AGENTS.md has accurate test counts and module list
- [ ] CHANGELOG.md has complete [1.0.0] entry
- [ ] CONTRIBUTING.md has correct scopes and test commands
- [ ] docs/behavior-spec.md matches all public APIs
- [ ] SKILL.md matches codebase exactly
- [ ] All doc cross-references verified
- [ ] No version discrepancies across any doc file

#### US-021: Version bump to 1.0.0
**Description:** As a developer, I want to ship version 1.0.0 with all features complete and all tests green.

**Acceptance Criteria:**
- [ ] Config.pmod `PMP_VERSION = "1.0.0"`
- [ ] All 208+ shell tests pass
- [ ] All 330+ Pike tests pass
- [ ] `pike bin/pmp.pike --help` shows correct version
- [ ] CI green on all workflows
- [ ] Git tag `v1.0.0` created
- [ ] GitHub release published with changelog

---

## Functional Requirements

### Core Infrastructure
- FR-1: User-Agent header MUST use Config.PMP_VERSION, not a hardcoded version string
- FR-2: All documentation files MUST accurately describe the current codebase
- FR-3: Test file names MUST reflect what they test
- FR-4: Every catch block MUST either propagate error details or document why it intentionally discards them
- FR-5: Store entry SHA prefix MUST be documented as 16 characters consistently

### Lockfile
- FR-6: Lockfile v2 format MUST include per-entry content_sha256 integrity field
- FR-7: Lockfile v2 MUST include a whole-file checksum for tamper detection
- FR-8: pmp MUST transparently migrate v1 lockfiles to v2 on first write
- FR-9: Lockfile filename changes from `pike.lock` to `pmp.lock` with automatic migration

### HTTP & Networking
- FR-10: HTTP caching MUST support ETag and Last-Modified conditional requests
- FR-11: Cache MUST be stored at `~/.pike/cache/http/`
- FR-12: `--offline` mode MUST read from cache when store entries exist
- FR-13: `pmp store prune` MUST also clean stale HTTP cache entries

### Version Resolution
- FR-14: pike.json MUST accept semver range constraints (`^`, `~`, `>=`, `<=`, `>`, `<`, `*`)
- FR-15: Resolution MUST pick the highest version satisfying the constraint
- FR-16: Lockfile MUST record the resolved exact version, not the range

### Commands
- FR-17: `pmp tree` MUST display the full dependency graph from lockfile
- FR-18: `pmp vendor` MUST download all lockfile deps for offline use
- FR-19: `pmp run` MUST auto-sync environment when lockfile is stale vs pike.json
- FR-20: `pmp run --with <dep>` MUST inject ephemeral dependencies without modifying project state
- FR-21: `pmp install` MUST prune modules not in lockfile (exact environment sync)
- FR-22: `pmp tree --depth N` MUST limit tree depth
- FR-23: `pmp run --no-sync` MUST skip auto-sync
- FR-24: `pmp install --no-prune` MUST skip stale module removal

### Workspaces
- FR-25: Root `pike.json` with `"workspace"` key MUST enable monorepo mode
- FR-26: Single `pmp.lock` MUST cover all workspace members
- FR-27: `--package <name>` flag MUST scope commands to a specific workspace member

---

## Already Decided (ADRs)

| ADR | Title | Phase | Status |
|-----|-------|-------|--------|
| ADR-0002 | HTTP Caching Strategy | Phase 2 | Decided, not implemented |
| ADR-0003 | Lockfile v2 Format | Phase 1 | Decided, not implemented |
| ADR-0004 | Semver Range Constraints | Phase 3 | Decided, not implemented |
| ADR-0005 | Workspace Support | Phase 6 | Decided, not implemented |

---

## Success Metrics

| Metric | Target | Current |
|--------|--------|---------|
| Shell tests | 250+ (208 + new) | 208 |
| Pike tests | 400+ (330 + new) | 330 |
| Doc inconsistencies | 0 | 30 |
| Known bugs | 0 | 3 |
| `pmp install` (warm, 10 deps) | < 500ms | Unknown (no benchmark) |
| `pmp run` overhead vs raw pike | < 100ms | Unknown |
| Lockfile integrity | Whole-file + per-entry | Per-entry only |
| Semver constraint support | Caret, tilde, range, wildcard | Exact pin only |
| Offline install from lockfile | Supported | Supported (already works) |
| HTTP caching | ETag + Last-Modified | None |

---

## Open Questions

1. **Lockfile v2 timing**: Should v1→v2 migration happen in v0.5.0 (before semver ranges) or alongside semver ranges in v0.6.0? Lockfile v2 is a prerequisite for semver ranges (need to record the constraint alongside the resolved version).
2. **`pmp.lock` vs `pike.lock`**: Should the rename happen in lockfile v2, or should we keep `pike.lock` for backward compatibility? A rename breaks every existing `.gitignore` entry.
3. **Workspace priority**: Is monorepo support actually needed by Pike projects, or is it aspirational? Should Phase 6 be deferred post-1.0?
4. **`pmpx` / global tools**: The `uvx`-style global tool runner is out of scope for 1.0 but should the architecture leave room for it?
5. **Test coverage target**: Should we aim for 100% module coverage (every module has a Pike test file) or focus on critical paths? Currently LockOps, Update, and Install have no dedicated Pike unit tests.

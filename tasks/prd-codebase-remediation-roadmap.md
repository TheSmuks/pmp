# PRD: PMP Codebase Remediation Roadmap

## Introduction

Full audit of the pmp codebase reveals a project that is **substantially real** — no stubs, no skeletons, no placeholder functions. All 18 modules contain implemented logic with meaningful error handling and security hardening. However, the audit uncovered three categories of problems that compound into technical debt and trust erosion:

1. **Hallucinated documentation** — `docs/behavior-spec.md` describes features that never existed (ETag caching, result caching with TTL, env var overrides for HTTP config, lock constants in Config.pmod). These fabrications were likely LLM-generated and never cross-verified against code.

2. **Brittle or missing test coverage** — Core install/download pipelines have zero unit-level tests. Several test files assert only "doesn't crash" or "contains substring 'done'", which pass even when the implementation is broken.

3. **Doc-code drift** — Stale test counts, wrong SHA prefix lengths, misleading CHANGELOG entries, offline flags documented for commands that don't accept them.

This PRD prioritizes fixes by severity: hallucinated docs first (they mislead every future contributor), then test gaps (they let regressions ship), then drift cleanup.

**Inspiration alignment**: pmp draws from bun (fast install, content-addressable store), uv (lockfile-centric reproducibility, virtual environments), and cargo (atomic operations, layered architecture, advisory locking). The current state delivers on ~60% of these aspirations. This roadmap closes the gap.

---

## Goals

- Eliminate all hallucinated documentation — every claim in every doc file matches code reality
- Close critical test gaps: install pipeline, tar extraction security, update verification
- Fix all doc-code drift: test counts, SHA prefix, offline flag claims, module descriptions
- Add `tar` dependency check before GitHub/GitLab downloads (current silent failure)
- Harden `cmd_rollback` to write complete lockfiles or none at all
- Add missing `--offline` flag support for `outdated`, `changelog`, `doctor` commands
- Establish doc sync verification in CI to prevent future drift

---

## User Stories

### US-001: Purge hallucinated features from behavior-spec.md
**Description:** As a contributor, I need the behavior spec to match the actual code so I can trust it as a reference instead of guessing what's real.

**Acceptance Criteria:**
- [ ] Remove "Results are cached in memory with a 60-second TTL" from Resolve.latest_tag section
- [ ] Remove "Pagination capped at MAX_TAG_PAGES (20) with warning" claim (no MAX_TAG_PAGES constant exists)
- [ ] Remove "Returns a copy of cached result" claim
- [ ] Remove "Caches api.github.com and gitlab.com/api responses with ETag support" from Http.http_get
- [ ] Remove "304 Not Modified: returns cached body if available" from Http.http_get_safe
- [ ] Remove LOCK_MAX_ATTEMPTS_STORE, LOCK_MAX_ATTEMPTS_PROJECT, LOCK_BACKOFF_BASE from Config constants table
- [ ] Remove env override columns (PMP_HTTP_TIMEOUT, PMP_HTTP_READ_TIMEOUT, PMP_HTTP_RETRIES, PMP_MAX_BODY_SIZE) from Http config table
- [ ] Fix merge_lock_entries description: "silently skipped" → "dies on empty name via die()"
- [ ] Fix write_lockfile description: "exactly 5 fields" → "at least 5 fields"
- [ ] All claims in behavior-spec.md verified against source code with line references

### US-002: Fix doc-code drift across all documentation
**Description:** As a contributor, I need consistent numbers and descriptions across AGENTS.md, ARCHITECTURE.md, README.md, and CHANGELOG.md.

**Acceptance Criteria:**
- [ ] ARCHITECTURE.md: SHA prefix updated from "8 characters" to "16 characters" in store entry name description
- [ ] README.md: store entry example updated from `a1b2c3d4` to 16-char example
- [ ] ARCHITECTURE.md: Pike test count updated from 317 to 325
- [ ] CHANGELOG.md: Pike test count updated from 317 to 325
- [ ] ARCHITECTURE.md: Helpers.pmod description includes all ~20+ functions, not just the original 7
- [ ] ARCHITECTURE.md: Env.pmod description includes `cmd_run` and `build_paths`
- [ ] ARCHITECTURE.md: Resolve.pmod description includes `_resolve_remote`, `_resolve_tags`, and safe variants
- [ ] ARCHITECTURE.md: Http.pmod description includes `_follow_with_redirects`, `_do_get_single`, SSRF helpers
- [ ] AGENTS.md: Remove "No external deps needed (no curl, tar, sha256sum)" — `tar` is required
- [ ] CHANGELOG.md [Unreleased]: Fix misleading "cmd_outdated --offline" entry — clarify that --offline only works as a flag to `pmp install`, not as a standalone flag for other commands
- [ ] pmp.pike help text: Remove "no external deps needed" claim or add tar to requirements

### US-003: Add `tar` dependency check
**Description:** As a user, I want clear errors when `tar` is not available instead of silent download-then-crash on GitHub/GitLab installs.

**Acceptance Criteria:**
- [ ] `install_one()` checks for `tar` command before calling `store_install_github()` or `store_install_gitlab()`
- [ ] Error message is actionable: "tar is required for GitHub/GitLab installs. Install tar or use self-hosted source."
- [ ] AGENTS.md updated to list `tar` as a dependency
- [ ] Test: `test_18_error_paths.sh` or new test verifies the error message when tar is unavailable
- [ ] `cmd_doctor()` checks for `tar` availability and reports status

### US-004: Harden cmd_rollback lockfile integrity
**Description:** As a user running rollback after a failed update, I need the lockfile to accurately reflect what was restored, not a partial subset.

**Acceptance Criteria:**
- [ ] `cmd_rollback()` tracks which entries failed to restore
- [ ] If any entries fail, the lockfile is written with ALL successfully restored entries AND a comment line listing failed entries
- [ ] User sees a summary: "Restored N/M entries. K entries could not be restored (listed in pike.lock with # prefix)"
- [ ] Test: simulate rollback where one store entry is missing, verify lockfile is complete with failure annotation

### US-005: Add top-level --offline flag support
**Description:** As a user working without network, I want `pmp outdated --offline`, `pmp changelog --offline`, and `pmp doctor --offline` to work as documented.

**Acceptance Criteria:**
- [ ] `pmp.pike` `_main()` parses `--offline` as a global flag (not just install-specific)
- [ ] `ctx["offline"]` is set before command dispatch for all commands
- [ ] `cmd_outdated()` with `ctx["offline"]` skips remote tag resolution, reports "offline mode: skipping remote checks"
- [ ] `cmd_changelog()` with `ctx["offline"]` skips remote API calls, reports "offline mode: no remote changelog"
- [ ] `cmd_doctor()` with `ctx["offline"]` skips network checks (token validation, remote connectivity)
- [ ] Update help text to show `--offline` as a global flag
- [ ] Test: `pmp outdated --offline` in a project with deps produces offline-mode message and exit 0

### US-006: Add integration test for install pipeline
**Description:** As a maintainer, I need to know the full download → store → symlink → lockfile pipeline works end-to-end, not just that individual functions don't crash.

**Acceptance Criteria:**
- [ ] New test file `tests/test_35_install_pipeline.sh` that:
  - [ ] Creates a temp project with a dependency on a real GitHub repo (or local git repo fixture)
  - [ ] Runs `pmp install`
  - [ ] Verifies store entry exists with correct hash
  - [ ] Verifies symlink points to store entry
  - [ ] Verifies lockfile has correct fields (name, source, tag, commit_sha, content_sha256)
  - [ ] Runs `pmp verify` and asserts exit 0
  - [ ] Runs `pmp install` again and asserts idempotent (no re-download)
- [ ] Test passes in CI without network (use local git repo fixture)

### US-007: Add tar extraction security test
**Description:** As a security-conscious maintainer, I need to verify that extract_targz rejects tar archives with path traversal attacks.

**Acceptance Criteria:**
- [ ] New Pike test `tests/pike/ExtractSecurityTests.pike` that:
  - [ ] Creates a tar archive with `../../etc/passwd` path entry
  - [ ] Verifies `extract_targz()` dies with appropriate error
  - [ ] Creates a tar archive with symlink pointing outside extraction dir
  - [ ] Verifies extraction detects and rejects the escape
- [ ] At least 5 adversarial test cases for tar extraction
- [ ] Tests registered in `pike_tests.sh` harness

### US-008: Fix weak test assertions
**Description:** As a maintainer, I need tests that catch real regressions, not just "didn't crash."

**Acceptance Criteria:**
- [ ] `test_22_update.sh`: verify that update actually changes the installed version (not just that output contains 'done')
- [ ] `test_25_self_update.sh`: at minimum verify that self-update output is semantically valid (version comparison message or "already up to date")
- [ ] `InstallAdversarialTests.pike`: at least 5 of the 10 print_update_summary tests verify actual output content (field count, version format, arrow direction)
- [ ] `test_21_changelog.sh`: add a successful changelog test (even if it requires a local git fixture)
- [ ] `test_10_store.sh`: replace sed-based store_entry_name test with a call to `pmp` and verify the output

### US-009: Add doc sync CI check
**Description:** As a maintainer, I need CI to catch doc-code drift before merge, not after.

**Acceptance Criteria:**
- [ ] New CI workflow or extension to `docs-check.yml` that:
  - [ ] Extracts test counts from JUnit XML and compares to AGENTS.md claims
  - [ ] Checks that behavior-spec.md function signatures match actual code
  - [ ] Verifies PMP_VERSION in Config.pmod matches ARCHITECTURE.md version
  - [ ] Verifies module count in module.pmod matches ARCHITECTURE.md count
  - [ ] Fails the build (not just warns) on mismatch
- [ ] Check runs on PRs to main
- [ ] AGENTS.md updated with new CI check description

### US-010: Mark aspirational ADRs correctly
**Description:** As a contributor reading ADRs, I need to know which decisions are implemented and which are plans.

**Acceptance Criteria:**
- [ ] ADR-0003 (lockfile v2): Change status from "Accepted" to "Proposed" since none of its changes are implemented
- [ ] ADR-0004 (semver ranges): Already "Proposed" — verify no CHANGELOG entry implies it's done
- [ ] ADR-0005 (workspaces): Already "Proposed" — verify no CHANGELOG entry implies it's done
- [ ] Add a note to ADR-0003: "Implementation pending. Current lockfile version is 1 (5-field TSV). This ADR describes a v2 format that has not been implemented."

---

## Functional Requirements

- FR-1: `docs/behavior-spec.md` must contain zero claims about features not present in the codebase
- FR-2: All doc files (AGENTS.md, ARCHITECTURE.md, README.md, CHANGELOG.md) must have consistent numbers (test counts, SHA prefix length, module counts)
- FR-3: `install_one()` must check for `tar` availability before attempting GitHub/GitLab downloads and die with actionable message if missing
- FR-4: `cmd_rollback()` must write complete lockfiles — either all entries restored, or partial restores annotated
- FR-5: `--offline` must be a global flag parsed in `_main()`, not an install-only flag
- FR-6: Test suite must include end-to-end install pipeline verification
- FR-7: Test suite must include tar extraction security tests
- FR-8: Weak test assertions (pass-on-broken) must be replaced with content-verified assertions
- FR-9: CI must verify doc-code consistency and block merge on drift
- FR-10: ADR status fields must reflect implementation reality

---

## Non-Goals (Out of Scope)

- No new features (semver ranges, workspaces, lockfile v2) — this is remediation only
- No refactoring of the module architecture — the layered layout is sound
- No performance optimization or benchmarking
- No multi-OS CI matrix addition (separate roadmap item)
- No release pipeline overhaul (no artifact signing, no tarballs)
- No install.sh security hardening (signature verification, rollback) — separate roadmap item
- No HTTP caching or ETag support implementation — the behavior-spec claims are removed, but the feature itself is not implemented (would be a future enhancement)
- No changes to the content-addressable store design

---

## Technical Considerations

### Current architecture strengths (preserve these)
- Layered module layout (core/transport/store/project/commands) — clean separation
- Content-addressable store with deterministic hashing — enables reproducibility
- Atomic operations (temp+rename for writes, staging dir for installs) — crash safety
- SSRF protection in Http.pmod — production-grade, covers IPv4/IPv6/octal/hex
- Advisory locking with stale detection — correct concurrent access
- Semver 2.0.0 compliance — spec-accurate implementation

### Known dependencies
- `tar` is required for GitHub/GitLab installs (despite docs claiming no external deps)
- `git` is required for self-hosted sources and `pmp self-update`
- Pike 8.0 is required (no version matrix testing exists)

### Pike-specific constraints
- Multiple inheritance creates flat namespaces — doc must reflect actual inheritance chain
- Environment variables used for shared mutable state (PMP_VERBOSE, PMP_QUIET, PMP_CLEANUP_DIRS) — this is intentional
- `inherit .Foo` vs `inherit Foo` both work due to PIKE_MODULE_PATH setup — mixed style in codebase is functional

---

## Priority / Execution Order

### Phase 1: Truth (eliminate hallucinations)
1. US-001: Purge behavior-spec.md fabrications
2. US-010: Fix ADR status fields
3. US-002: Fix doc-code drift

**Why first:** Every subsequent decision relies on accurate docs. Contributors and agents currently cannot trust the behavior-spec. This is the root cause of future bugs.

### Phase 2: Safety (close test gaps)
4. US-003: Add tar dependency check
5. US-007: Add tar extraction security tests
6. US-006: Add install pipeline integration test
7. US-008: Fix weak test assertions

**Why second:** Tests prevent regressions. The install pipeline, tar extraction, and update commands currently ship with no meaningful verification. This is where bugs hide.

### Phase 3: Correctness (fix behavioral gaps)
8. US-004: Harden cmd_rollback
9. US-005: Add global --offline flag

**Why third:** These are real behavioral bugs that affect users, but they don't cause data loss. They're next in priority after truth and safety.

### Phase 4: Prevention (prevent future drift)
10. US-009: Add doc sync CI check

**Why last:** This prevents the problem from recurring but doesn't fix current issues. Must follow Phase 1 since the CI check needs accurate baseline docs to enforce against.

---

## Success Metrics

- Zero fabricated claims in behavior-spec.md
- All doc files agree on: test counts, SHA prefix length, module counts, version number
- Install pipeline has end-to-end test coverage (download → store → symlink → lockfile)
- No test file passes when its target function is a no-op
- `pmp outdated --offline`, `pmp changelog --offline`, `pmp doctor --offline` work as standalone commands
- CI blocks merge on doc-code drift

---

## Open Questions

1. Should behavior-spec.md sections for caching (TTL, ETag) be removed entirely, or should they be kept as "planned behavior" with a status note? **Recommendation:** Remove. Add a `## Planned Features` section at the end if needed.
2. For the install pipeline test (US-006), should we use a real GitHub repo fixture (fragile if repo changes) or create a local git repo with tags? **Recommendation:** Local git fixture. Deterministic, no network, CI-stable.
3. Should the tar dependency check be added to `cmd_doctor()` output? **Recommendation:** Yes. doctor already checks for git and pike. tar is equally critical.
4. Should `install.sh` be updated to check for `tar` before proceeding? **Recommendation:** Yes. Currently checks for git and pike only.

---

## Audit Findings Reference

### Fabricated Features (behavior-spec.md)
| ID | Claim | Reality |
|---|---|---|
| D1 | Resolve.latest_tag caches with 60s TTL | No caching exists anywhere |
| D2 | Http.http_get caches with ETag support | No ETag code exists |
| D3 | Config has LOCK_MAX_ATTEMPTS_*, env overrides for HTTP | Only PMP_VERSION, EXIT_*, verbose/quiet |
| D23 | ADR-0003 lockfile v2 "Accepted" | Nothing implemented, still on v1 |
| D30 | CHANGELOG: "cmd_outdated --offline" | --offline only parsed by cmd_install |

### Critical Test Gaps
| Feature | Tests | Gap |
|---|---|---|
| install_one() full pipeline | 0 unit tests | Only shell E2E with local deps |
| store_install_github/gitlab | 0 unit tests | Only store_entry_name tested |
| extract_targz security | 0 tests | Symlink traversal untested |
| cmd_update version change | Weak ("contains 'done'") | Doesn't verify version changed |
| http_get retry/backoff | 0 unit tests | Only SSRF helpers tested |

### Weak Tests (pass when broken)
| File | Issue |
|---|---|
| InstallAdversarialTests.pike (all 10) | Only assert "doesn't throw", not output correctness |
| test_22_update.sh | Asserts "done" in output, not version change |
| test_25_self_update.sh | Accepts 5 broad output patterns |
| test_21_changelog.sh | Only tests error paths, no success case |

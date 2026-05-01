# PRD: PMP Codebase Audit & Strategic Roadmap

## Introduction

Full audit of the pmp codebase (v0.4.0-dev, Pike Module Package Manager) comparing documented claims against actual implementation, identifying what's brittle/failing/hallucinated, and establishing a clear roadmap inspired by bun, uv, and cargo.

The codebase has undergone two major refactorings (sh→Pike at v0.2.0, flat→layered at v0.3.0→0.4.0), survived a 6-agent adversarial audit (111 findings), and received significant fixes. The remaining work falls into three categories: **real bugs that survived the fixes**, **documentation/code misalignment that will mislead contributors**, and **strategic gaps** where pmp falls short of its inspirations (bun, uv, cargo).

### Audit Method

- Read all 17 source modules across 5 layers (core, transport, store, project, commands)
- Ran all tests: 174 shell (pass), 107 Pike unit (pass, PUnit exits 1 erroneously)
- Compared AGENTS.md, ARCHITECTURE.md, README.md, CHANGELOG.md, behavior-spec.md against actual code
- Cross-referenced prior adversarial audit (AUDIT_CONSOLIDATED.md) findings against current code to identify what was fixed vs what remains
- Checked install.sh, CI workflows, test infrastructure

---

## Part A: What's Actually Wrong

### Category 1: Confirmed Bugs (Code vs Reality)

#### BUG-001: install.sh reads Config.pmod from stale path

- **File**: `install.sh` line 157
- **What**: `_conf="$PMP_INSTALL_DIR/bin/Pmp.pmod/Config.pmod"` — but Config.pmod is now at `bin/core/Config.pmod`. The `bin/Pmp.pmod/` directory only contains `module.pmod`.
- **Impact**: Fresh installs show no version number in success message. Non-breaking but confusing.
- **Fix**: Change to `_conf="$PMP_INSTALL_DIR/bin/core/Config.pmod"`

#### BUG-002: Stale lockfile in project root

- **File**: `pike.lock`
- **What**: Contains entries for `inner-lib` and `outer-lib` (paths `./libs/inner-lib`, `./libs/outer-lib`) which are test artifacts. Neither directory exists. The lockfile does NOT contain entries for `punit-tests` or `bak-lib` which ARE in `pike.json`.
- **Impact**: Lockfile is out of sync with manifest. `pmp verify` would report issues.
- **Fix**: Regenerate lockfile with `pmp lock` or `pmp install`.

#### BUG-003: PUnit exit code 1 on all-pass

- **File**: PUnit (external dependency)
- **What**: `pike_tests.sh` runs PUnit which exits 1 even when 0 tests fail. All 107 TAP results are "ok", 0 "not ok".
- **Impact**: CI sees exit 1 and may report failure despite all tests passing. The `pike_tests.sh` wrapper likely masks this.
- **Fix**: Investigate PUnit version or patch the exit code handling.

#### BUG-004: classify_bump returns "prerelease" for patch-level prerelease changes

- **File**: `bin/core/Semver.pmod` line 194-197
- **What**: When patch differs AND new version has a prerelease, classify_bump returns "prerelease" instead of "patch". Example: `1.2.3` → `1.2.4-alpha` returns "prerelease" when it should return "patch" (the patch number changed).
- **Impact**: `pmp update` shows wrong bump classification in summary table.
- **Fix**: Check major/minor/patch first. Only classify as "prerelease" when major.minor.patch is identical.

#### BUG-005: Transitive deps of kept modules not resolved on non-force install

- **File**: `bin/commands/Install.pmod` (install_one)
- **What**: When a non-force install finds an existing version that doesn't match the requested version but force is not set, it records the kept version in lock_entries and returns early. Transitive deps of the kept version are NOT resolved. Only the fresh-install path resolves transitives.
- **Impact**: Lockfile may be missing transitive deps if the user runs `pmp install` with an existing module whose version doesn't match but isn't forced.
- **Fix**: After recording the kept version, also resolve its transitive deps from the store entry's pike.json.

### Category 2: Stale/Incorrect Documentation

#### DOC-001: behavior-spec.md claims partial versions accepted — code rejects them

- **File**: `docs/behavior-spec.md` line 23 vs `bin/core/Semver.pmod` line 62
- **What**: Spec says `"1"` → `{major:1, minor:0, patch:0}`. Code now has `if (sizeof(parts) != 3) return 0;` — strict 3-part only.
- **Impact**: Contributors following the spec will write wrong code/tests.
- **Fix**: Update behavior-spec.md to reflect strict semver parsing.

#### DOC-002: behavior-spec.md module paths reference flat layout

- **File**: `docs/behavior-spec.md` line 5
- **What**: Says "Module paths are relative to `bin/Pmp.pmod/`" but modules are now in `bin/core/`, `bin/transport/`, etc.
- **Impact**: Misleading for contributors.
- **Fix**: Update to reference layered directory structure.

#### DOC-003: CHANGELOG.md claims install.sh uses `set -euo pipefail` — actually `set -eu`

- **File**: `CHANGELOG.md` line 108
- **What**: "Added `set -euo pipefail` to the installer script" — but install.sh line 1 uses `set -eu` (no `-o pipefail`).
- **Impact**: False security claim.
- **Fix**: Either add `-o pipefail` to install.sh or update CHANGELOG.

#### DOC-004: AGENTS.md references flat module layout

- **File**: `AGENTS.md` architecture section
- **What**: Lists `bin/Pmp.pmod/` with 14 sub-modules flat. Actual structure is 5 directories with 17 modules.
- **Impact**: Misleading for contributors and agents.
- **Fix**: Rewrite architecture section to match actual directory layout.

#### DOC-005: AGENTS.md test counts stale

- **File**: `AGENTS.md` setup section
- **What**: Says "119 passed, 0 failed" and "81 Pike unit tests". Actual: 174 shell, 107 Pike.
- **Impact**: Agents can't validate test runs correctly.
- **Fix**: Update to 174 shell + 107 Pike.

#### DOC-006: libs/ contains test artifacts

- **File**: `libs/local-mod/`
- **What**: Not referenced in any manifest. Dead test artifact.
- **Impact**: Clutter, confusing for contributors.
- **Fix**: Remove or gitignore.

### Category 3: Structural/Hygiene Issues

#### STRUC-001: module.pmod flat inherit is architecturally redundant

- **File**: `bin/Pmp.pmod/module.pmod`
- **What**: 17 bare inherits that work only because the sh shim puts all directories on PIKE_MODULE_PATH. The module.pmod aggregator exists solely because `pmp.pike` does `import Pmp;`. Without module.pmod, direct imports would work via PIKE_MODULE_PATH.
- **Impact**: Not a bug, but adds confusion. Every new module requires adding an inherit line.
- **Fix**: Consider whether `import Pmp;` → flat aggregator is worth keeping vs switching to explicit imports.

#### STRUC-002: _read_json_mapping returns 0 for non-mapping JSON

- **File**: `bin/core/Helpers.pmod`
- **What**: If a JSON file contains an array or string instead of a mapping, `_read_json_mapping` returns 0 (same as "file not found"). Callers can't distinguish "missing" from "wrong type".
- **Impact**: Data corruption in pike.json would be silently treated as "missing" rather than reported.
- **Fix**: Return different error indicators or die on type mismatch.

#### STRUC-003: No shared dependency name validation

- **What**: Name validation is fragmented: `cmd_remove` rejects `/`, `..`, `\0`; `add_to_manifest` has no validation; `parse_deps` has no validation.
- **Impact**: A name with special characters can be stored via `add_to_manifest` but not removed via `cmd_remove`.
- **Fix**: Extract `validate_dep_name()` into Helpers or Source module. Call it at all entry points.

### Category 4: Audit Findings That Were Fixed

The adversarial audit (111 findings) identified many real issues. The following were confirmed fixed in current code:

- **C-01** (run_cleanup dead code): Now called in die(), die_internal(), and signal handlers
- **C-03** (Cache.pmod dead code): Removed (ADR-0002)
- **C-05** (credential leakage): sanitize_url() added
- **C-06** (SSRF): Private IP blocklist implemented
- **C-07** (file:// handling): Rejected with clear error
- **C-08** (symlink extraction TOCTOU): extract_targz validates paths
- **C-10** (SHA truncation): Now 16 chars
- **C-11–C-16** (semver violations): All fixed — strict 3-part, leading zero rejection, prerelease validation
- **C-17** (update deadlock): project_lock moved to shared Helpers
- **C-18** (install.sh POSIX): Fixed (uses `set -eu`)
- **H-06** (info/warn formatting): Addressed with verbosity checks
- **SEC-01 through SEC-08**: All addressed

### Category 5: Audit Findings Still Outstanding

These remain from the adversarial audit and haven't been addressed:

- **C-02**: atomic_write fallback still non-atomic (disk full, permissions)
- **C-04**: No Content-Length validation after HTTP download (mitigated by SHA-256)
- **C-09**: Hash verified after extraction, not before commit (mitigated by cleanup)
- **H-01**: json_field silently returns 0 for non-string values
- **H-04**: compute_sha256 doesn't verify file exists mid-stream
- **H-09**: Silent partial pagination for stale latest tags (partially mitigated)
- **H-14**: Redirect cycle detection is count-based not URL-based
- **H-18**: No disk space check before extraction
- **H-28**: Modules installed but lockfile write fails → inconsistent state (partially mitigated by backup)
- **H-31**: Store prune may delete entries referenced by broken symlinks
- **H-34**: cmd_changelog no common ancestor handling

---

## Part B: What's Hallucinated (Documented but Not Real)

These are features/claims in docs that don't match what the code actually does:

1. **"module.pmod Re-exports all sub-modules (15 total) via inherit"** — AGENTS.md says 14 sub-modules in one place, 15 in another, actual is 17 modules across 5 directories.

2. **"run_cleanup() never called on normal exit"** — This was fixed. AGENTS.md and ARCHITECTURE.md may still carry caveats from when it was true.

3. **behavior-spec.md partial version handling** — Spec says `"1"` is accepted. Code rejects it. Spec is wrong.

4. **"install.sh uses set -euo pipefail"** — CHANGELOG says this. install.sh only uses `set -eu`.

5. **"119 passed, 0 failed"** — AGENTS.md setup section. Actual is 174 shell + 107 Pike.

6. **README.md missing documented commands**: `pmp add`, `pmp outdated`, `pmp install --frozen-lockfile`, `pmp install --offline` are implemented but not in README.

---

## Part C: Strategic Roadmap — Inspired by bun, uv, cargo

### Where pmp is today

pmp is a working package manager that handles the basics: install, version resolution, lockfile, store, transitive deps, and basic CLI. It's at the stage where **it works for its author** but has gaps that would frustrate a new user or break in edge cases.

### Where bun/uv/cargo set the bar

| Capability | bun | uv | cargo | pmp current |
|---|---|---|---|---|
| Lockfile integrity | Binary lockfile with content hash | uv.lock with checksums | Cargo.lock with checksum | Text lockfile with SHA-256 (no integrity field) |
| Workspace/monorepo | package.json workspaces | uv workspace | Cargo workspace | Not supported |
| Version constraints | Caret, tilde, ranges | PEP 440 ranges | Semver ranges | Exact tags only |
| Global install | -g flag, global node_modules | uv tool install | cargo install | Documented but minimal |
| Offline mode | Full offline cache | Full wheel cache | cargo fetch + offline | --offline flag exists, basic |
| Parallel downloads | All parallel | All parallel | Parallel by default | Sequential |
| Config file | bunfig.toml | pyproject.toml | Cargo.toml | pike.json (minimal) |
| Plugin/extension | Plugin API | — | — | None |
| Script runner | bun run | uv run | cargo run | pmp run (basic) |
| Self-update | — | uv self update | rustup update | pmp self-update (git-based) |

### Roadmap Phases

#### Phase 1: Fix What's Broken (v0.4.0 release)

**Goal**: Ship a release where docs match code and all known bugs are fixed.

Stories: US-001 through US-012 below.

#### Phase 2: Reliability & Correctness (v0.5.0)

**Goal**: Handle edge cases gracefully. No silent failures. Atomic operations everywhere.

- Lockfile v2 with integrity checksum per line (ADR-0003 exists as design)
- Atomic operations for cmd_remove, cmd_clean, cmd_install_all (transaction log or staging)
- Content-Length validation on HTTP downloads
- Disk space checking before extraction
- Parallel downloads (Pike's threading)
- Proper error categorization (consistent return-vs-die contract)
- Shared dependency name validation

#### Phase 3: Developer Experience (v0.6.0)

**Goal**: Match cargo/bun ergonomics. Zero-friction onboarding.

- Workspace/monorepo support (ADR-0005 exists as design)
- Version constraints: caret (^1.2.3), tilde (~1.2.3), ranges (ADR-0004 exists as design)
- `pmp add` with automatic version selection (latest stable by default)
- `pmp why <module>` — show which dependency requires it
- `pmp tree` — dependency tree visualization
- Progress bars for downloads
- Colored output (respects NO_COLOR)
- Tab completion (bash, zsh, fish)
- `pmp doctor` enhanced — auto-fix where safe

#### Phase 4: Ecosystem (v0.7.0+)

**Goal**: Make pmp the standard way to distribute Pike modules.

- Registry support (not just git URLs) — pmp-registry or GitHub-only registry
- `pmp publish` — publish to registry
- `pmp search <query>` — search registry
- `pmp login` — registry authentication
- Package templates (`pmp new <name>` with scaffolding)
- `pmp test` — run project tests with correct PIKE_MODULE_PATH
- `pmp bench` — benchmark runner
- `pmp doc` — generate and serve documentation
- CI/CD templates for Pike projects

---

## User Stories

### US-001: Fix install.sh Config.pmod path
**Description:** As a user installing pmp via curl, I want to see the version number confirmed after install so that I know the right version was installed.

**Acceptance Criteria:**
- [ ] install.sh reads version from `bin/core/Config.pmod` (not `bin/Pmp.pmod/Config.pmod`)
- [ ] Fresh install shows "Installed pmp v0.4.0 to ..."
- [ ] Existing install update shows correct version
- [ ] Shell test for install path passes

### US-002: Regenerate stale project lockfile
**Description:** As a developer working on pmp, I want the project lockfile to match pike.json so that `pmp verify` passes on the project itself.

**Acceptance Criteria:**
- [ ] `pike.lock` contains entries matching `pike.json` dependencies
- [ ] No stale test artifact entries (inner-lib, outer-lib)
- [ ] `pmp verify` exits 0 on the project

### US-003: Fix classify_bump for patch-level prerelease
**Description:** As a user running `pmp update`, I want the bump classification to be accurate so I can make informed decisions about updates.

**Acceptance Criteria:**
- [ ] `classify_bump("1.2.3", "1.2.4-alpha")` returns "patch" (not "prerelease")
- [ ] `classify_bump("1.2.3", "1.2.3-alpha")` returns "prerelease" (patch identical, only pre changed)
- [ ] `classify_bump("1.2.3-alpha", "1.2.3")` returns "prerelease"
- [ ] `classify_bump("1.2.3", "2.0.0-alpha")` returns "major"
- [ ] Existing classify_bump tests pass
- [ ] New test cases added for patch+prerelease combinations

### US-004: Fix transitive dep resolution for kept modules
**Description:** As a user running `pmp install` with an existing module, I want transitive dependencies to be resolved even when the existing version is kept.

**Acceptance Criteria:**
- [ ] When install_one keeps an existing version, it still resolves transitive deps from the store entry's pike.json
- [ ] Lockfile contains all transitive deps after `pmp install`
- [ ] No regression in existing install tests

### US-005: Update behavior-spec.md for strict semver
**Description:** As a contributor reading the behavior spec, I want it to match what the code actually does so I don't write incorrect code.

**Acceptance Criteria:**
- [ ] Partial versions section removed or updated to say they're rejected
- [ ] Module paths updated from `bin/Pmp.pmod/` to layered directories
- [ ] All edge cases in spec match actual parse_semver behavior

### US-006: Update AGENTS.md for current codebase state
**Description:** As an AI agent or contributor reading AGENTS.md, I want accurate architecture and test information so I can work effectively.

**Acceptance Criteria:**
- [ ] Architecture section reflects 5-layer directory structure (core, transport, store, project, commands)
- [ ] Module list shows 17 modules across 5 directories
- [ ] Test counts updated to 174 shell + 107 Pike
- [ ] Key functions list matches actual exports
- [ ] Module design principles updated for layered structure

### US-007: Fix CHANGELOG.md install.sh pipefail claim
**Description:** As a reader of CHANGELOG.md, I want security claims to be accurate.

**Acceptance Criteria:**
- [ ] Either install.sh has `set -euo pipefail` or CHANGELOG says `set -eu`
- [ ] The claim is verified by reading install.sh

### US-008: Update README.md with all implemented commands
**Description:** As a new user reading README, I want to see all available commands so I don't miss features.

**Acceptance Criteria:**
- [ ] `pmp add <url>` documented
- [ ] `pmp outdated` documented
- [ ] `pmp install --frozen-lockfile` documented
- [ ] `pmp install --offline` documented
- [ ] `pmp store prune --force` documented
- [ ] Command table matches `pmp --help` output exactly

### US-009: Remove stale test artifacts
**Description:** As a contributor cloning the repo, I want a clean workspace without leftover test files.

**Acceptance Criteria:**
- [ ] `libs/local-mod/` removed or documented
- [ ] All `.tmp-*` files/dirs in project root cleaned up and added to .gitignore
- [ ] `pike.lock.prev` regenerated or removed from tracking

### US-010: Investigate and fix PUnit exit code
**Description:** As a developer running Pike tests, I want exit code 0 when all tests pass so CI works correctly.

**Acceptance Criteria:**
- [ ] `pike_tests.sh` exits 0 when all tests pass
- [ ] PUnit exit code investigated and fix documented
- [ ] CI doesn't false-negative on passing tests

### US-011: Add shared dependency name validation
**Description:** As a developer, I want a single validation function for dependency names used at all entry points.

**Acceptance Criteria:**
- [ ] `validate_dep_name()` function added to Source or Helpers module
- [ ] Called in `add_to_manifest`, `cmd_remove`, and `parse_deps`
- [ ] Rejects `/`, `..`, `\0`, empty strings, names with newlines/tabs
- [ ] Tests for valid and invalid names

### US-012: Fix _read_json_mapping to distinguish missing from malformed
**Description:** As a developer, I want to know when pike.json has the wrong structure vs when it's missing.

**Acceptance Criteria:**
- [ ] `_read_json_mapping` returns 0 for missing files
- [ ] `_read_json_mapping` dies with clear error for valid JSON that isn't a mapping
- [ ] Existing callers handle the distinction correctly
- [ ] Tests for both paths

---

## Functional Requirements

- FR-1: install.sh version detection must read from `bin/core/Config.pmod`
- FR-2: Project lockfile must be synchronized with `pike.json`
- FR-3: `classify_bump` must check major/minor/patch differences before prerelease classification
- FR-4: `install_one` must resolve transitive deps for kept-existing modules
- FR-5: behavior-spec.md must match actual code behavior for semver parsing
- FR-6: AGENTS.md must reflect the 5-layer directory structure
- FR-7: CHANGELOG.md security claims must be verifiable
- FR-8: README.md command documentation must include all implemented commands
- FR-9: Stale test artifacts must not be in the repository
- FR-10: Pike test runner must exit 0 on all-pass
- FR-11: Dependency name validation must be centralized and consistent
- FR-12: `_read_json_mapping` must distinguish missing from malformed JSON

## Non-Goals (Out of Scope)

- No new features (workspaces, version ranges, registry) — those are Phase 3+
- No lockfile v2 migration — that's Phase 2
- No parallel downloads — Phase 2
- No plugin system — Phase 4
- No breaking changes to lockfile format or CLI interface
- No changes to the Pike language or runtime

## Design Considerations

- The layered directory structure (core/transport/store/project/commands) is correct and should be the canonical reference in all documentation
- The flat `module.pmod` aggregator works but is a maintenance burden — document it clearly or phase it out
- All doc updates should be cross-checked: AGENTS.md ↔ ARCHITECTURE.md ↔ README.md ↔ behavior-spec.md
- Test infrastructure is solid (runner.sh + helpers.sh + PUnit) — don't replace it, just fix the exit code issue

## Technical Considerations

- Pike's `inherit` copies state — the flat aggregator in module.pmod works because all inherited modules use constants or env-var-backed shared state
- The sh shim's PIKE_MODULE_PATH is the mechanism that makes the layered structure work with bare inherits
- PUnit is an external dependency — if it has a bug, we may need to patch or work around it
- The `.tmp-*` files in the project root are from test runs that didn't clean up — the trap-based cleanup in helpers.sh should handle this, but something is leaking

## Success Metrics

- All 174 shell tests pass with exit 0
- All 107 Pike unit tests pass with exit 0
- `pmp verify` passes on the pmp project itself
- No stale artifacts in the repository root
- `install.sh` shows correct version on fresh install
- Documentation accurately reflects code in all 4 doc files
- `classify_bump` returns correct classification for all version transition types

## Open Questions

- Should `module.pmod` be kept as a flat aggregator, or should pmp.pike use explicit imports from each layer?
- Should lockfile v2 (ADR-0003) be prioritized before workspace support (ADR-0005)?
- Is the PUnit exit code issue in PUnit itself or in our run.pike wrapper?
- Should `pmp doctor --fix` auto-repair issues, or just report them?
- What's the target Pike version compatibility? 8.0 only, or 7.8+?

---

## Appendix: Audit Summary

| Category | Count | Status |
|---|---|---|
| Confirmed bugs | 5 | Fix in Phase 1 |
| Stale documentation | 6 | Fix in Phase 1 |
| Structural/hygiene issues | 3 | Fix in Phase 1-2 |
| Prior audit findings (fixed) | ~30 | Done |
| Prior audit findings (outstanding) | ~12 | Phase 2 |
| Strategic gaps vs bun/uv/cargo | ~15 | Phase 2-4 |
| Test suites | 18 | All passing |
| Test count | 281 total (174 shell + 107 Pike) | All passing |

# Changelog

All notable changes to pmp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

8zz|## [Unreleased]
9co|
### Added
feat(cli): `pmpx` command — download and execute a Pike module without installing (`pmp pmpx github.com/owner/repo [-- args...]`)
test(cli): shell and Pike unit tests for pmpx (error paths, entry point resolution, cache reuse, no side effects)
### Fixed
11ke|fix(docs): corrected AGENTS.md line counts (Verify ~269, Update ~210, LockOps ~281) and total source (~4825)
11ke|fix(install): install.sh now uses `^{commit}` to dereference annotated tags during version verification — prevents false checksum mismatch on annotated tag checkouts
12ke|fix(docs): corrected ARCHITECTURE.md line counts (pmp.pike ~274, Install.pmod ~582)
13ke|fix(docs): updated AGENTS.md and ARCHITECTURE.md shell test count to 211 (were 172 in ARCHITECTURE.md)
14ke|fix(docs): updated install.sh and README.md version examples to v0.4.0
15ke|fix(docs): updated Pike test file names in ARCHITECTURE.md (SourceAdversarialTests, LockfileAdversarialTests, HelpersAdversarialTests, etc.)
16ke|fix(docs): updated Helpers.pmod function list in AGENTS.md (added atomic_symlink, atomic_write, validate_dep_name, advisory_lock/unlock, make_temp_dir, resolve_local_path, register/unregister_cleanup_dir, run_cleanup)
17vv|fix(docs): updated Validate.pmod function list in AGENTS.md (added strip_comments_and_strings, init_std_libs)
18jk|fix(docs): extended scripts/doc-sync-check.sh with line count consistency checks (Verify/Update/LockOps, pmp.pike, Install.pmod totals, shell test count match)
18to|
19rz|## [0.4.0] - 2026-05-01

### Added

feat: global `--offline` flag works with any command (`pmp outdated --offline`, `pmp changelog --offline`, `pmp doctor --offline`)
feat: `tar` dependency check before GitHub/GitLab installs with actionable error message
feat: `tar` availability reporting in `pmp doctor`
feat: `scripts/doc-sync-check.sh` — CI-enforced doc-code consistency (blocks merge on drift)
feat: `cmd_rollback` now reports 'restored N of M modules' with per-entry failure listing
feat: `tests/test_35_install_pipeline.sh` — 26-assertion end-to-end install pipeline test with local git fixture
feat: `tests/pike/ExtractSecurityTests.pike` — 5 adversarial tar extraction security tests
feat: extract `prune_stale_deps()` to Lockfile.pmod — shared BFS transitive dep pruning used by both `cmd_install_all` and `cmd_update`
feat: `sanitize_url()` in Helpers.pmod — strips credentials from URLs before display in error messages
feat: offline mode hardened — install --offline sets ctx for downstream; cmd_outdated, cmd_changelog, cmd_doctor skip network calls when ctx["offline"] is set (currently only via install --offline)
feat: path traversal protection for resolved local dependency paths — validates resolved path stays within project root
feat: IPv6 SSRF bypass fix — explicit `::1` and `::` checks before expansion, fixed `::` group count bug
feat: 4 new sanitize_url tests, 1 new file:// rejection test, 2 new path traversal tests
feat: StoreCmdAdversarialTests.pike — 11 new tests for dir_size, human_size, and store pruning logic
feat: 4 new Semver adversarial tests for prerelease leading zeros (S-01), at-sign rejection (S-04), build metadata validation (S-05), and build metadata leading zeros acceptance (S-06)
feat: PUnit as a dev dependency (`pike.json`) with Pike-level unit tests (81 tests) for `Semver`, `Source`, `Lockfile`, and `Helpers` pure-function modules
feat: `tests/pike_tests.sh` entry point — installs PUnit and runs tests via `sh tests/pike_tests.sh`
feat: `tests/pike/` directory with `run.pike` harness and 4 test files: `SemverTests.pike`, `SourceTests.pike`, `LockfilePureTests.pike`, `HelpersTests.pike`
feat: Adopted ai-project-template v0.2.0 — added `.editorconfig`, `.gitattributes`, `.architecture.yml`, issue/PR templates, CODEOWNERS, SECURITY.md, dependabot.yml, commit-lint/changelog-check/blob-size-policy workflows, `.omp/` agent definitions, `docs/ci.md`, and ADR 0001
feat: `--verbose` / `--quiet` CLI flags and `PMP_VERBOSE` / `PMP_QUIET` environment variables
feat: `debug()` logging function for verbose output
feat: `die_internal()` for assertion-style failures with exit code 2
feat: Column headers in `pmp list` output (`MODULE`, `VERSION`, `SOURCE`)
feat: Module count in `pmp clean` summary
feat: `pmp init` now verifies write success
feat: `pmp store prune` now deletes unused store entries (with confirmation)
docs: ADR 0003 — lockfile v2 design with integrity field and checksum
docs: ADR 0004 — semver range constraints design (caret, tilde, wildcard)
docs: ADR 0005 — workspace (monorepo) support design
docs: ARCHITECTURE.md version corrected to 0.4.0, layer count to 5, test counts to 174+325
docs: AGENTS.md test counts updated, Helpers.pmod description includes new functions
docs: stale comments fixed in pmp.pike and Install.pmod
docs: removed aspirational TODO from ConfigTests.pike
docs: added TigerBeetle's Tiger Style coding guide (docs/TIGER_STYLE.md) as a project reference

### Changed

refactor: restructure all 17 modules into canonical Pike layout under `bin/Pmp.pmod/` (flat, no subdirectories)
refactor: `module.pmod` is now namespace-only — no `inherit` re-exports, sub-modules use `import .Foo;`
refactor: shell shim sets single `PIKE_MODULE_PATH` instead of 6 colon-separated entries
refactor: `pmp.pike` uses explicit imports (`import Pmp.Config; import Pmp.Helpers;` etc.)
refactor: `Config`, `Helpers`, etc. are no longer importable as top-level modules (namespace pollution eliminated)
refactor: moved `project_lock`/`project_unlock` from Install.pmod to Helpers.pmod (architecturally correct placement)
refactor: moved `store_lock`/`store_unlock` from Store.pmod to Helpers.pmod
refactor: extracted `_follow_with_redirects()` — shared HTTP redirect/SSRF logic, removed 60 lines of duplication from http_get/http_get_safe
refactor: extracted `_resolve_remote()` — shared resolve dispatch, consolidated 6 near-duplicate github/gitlab resolve functions
refactor: reorganized flat bin/Pmp.pmod/ into layered domain directories (core, transport, store, project, commands) following separation of concerns
refactor: updated sh shim and pike_tests.sh to include layered PIKE_MODULE_PATH entries
refactor: decomposed Install.pmod (1042 lines) into Install.pmod (~600 lines), Update.pmod (~200 lines), and LockOps.pmod (~280 lines) for focused single-responsibility modules
refactor: deduplicated Pike test suites — removed LockfilePureTests, HelpersTests, SourceTests (merged into adversarial counterparts), removed classify_bump/merge_lock_entries duplicates from InstallAdversarialTests and ResolveAdversarialTests
refactor: restructured test suite — split `tests/test_install.sh` (803 lines, 97 tests) into a test runner (`tests/runner.sh`) + 25 individual test files with numeric sort ordering
refactor: `tests/helpers.sh` with extracted assertion functions and setup utilities
refactor: `tests/test_install.sh` is now a thin shim that delegates to `tests/runner.sh`
refactor: `cmd_rollback` now warns and continues on missing store entries instead of aborting
refactor: Exit codes documented in help text (0 success, 1 user error, 2 internal error)
refactor: Environment variable reference in help text (`GITHUB_TOKEN`, `PIKE_BIN`, `TMPDIR`, `PMP_VERBOSE`, `PMP_QUIET`)
refactor: `install.sh` verifies `pmp version` works after install
refactor: `install.sh` `git fetch --all --tags` before checkout on update
refactor: PUnit version pinned in `pike.json` to prevent breaking CI on upstream releases
refactor: docs reconciled with actual codebase — corrected module counts (17 modules across 5 layers), test counts (211 shell + 342 Pike), added verify/doctor commands to README
refactor: Updated `.gitignore` with IDE/OS/environment patterns from template
refactor: Updated `CONTRIBUTING.md` with branch naming conventions and expanded guidelines
refactor: Updated `README.md` with changelog badge
refactor: Updated `AGENTS.md` with CI workflow table, agent behavior section, and template version tracking
refactor: Rewrote `.agents/skills/pmp-dev/SKILL.md` to reflect current Pike architecture (was describing pre-0.3.0 POSIX sh implementation)
refactor: Updated `ARCHITECTURE.md` to reflect current version (0.4.0), module list (17 modules across 5 layers), and line counts
refactor: Updated `install.sh` version pin example to `v0.3.0`
refactor: Updated `RELEASE.md` with correct syntax check command and Pike test command
refactor: Updated `CONTRIBUTING.md` and `docs/ci.md` with Pike test commands
fix(docs): purged hallucinated features from behavior-spec.md — removed caching/TTL/ETag/non-existent Config constants
fix(docs): ADR-0003 lockfile v2 status corrected from Accepted to Proposed (not implemented)
fix(docs): SHA prefix corrected from 8 to 16 chars across ARCHITECTURE.md, README.md
fix(docs): test counts corrected to 211 shell + 342 Pike across all doc files
fix(docs): AGENTS.md now lists tar as an external dependency (was claiming no external deps)
fix(docs): offline flag CHANGELOG entry corrected to reflect actual implementation scope
fix(install): Config.pmod path updated from bin/Pmp.pmod/ to bin/core/ in install.sh
fix(tests): convert in-process die() tests to subprocess in LockfileIOAdversarialTests and ManifestAdversarialTests
fix(deps): parse_deps no longer dies on malformed JSON (resilient query function)
fix(install): resolve transitive deps for kept-existing modules
fix: `pmp update <module>` now prunes stale transitive deps (BFS walk from direct deps)
fix: `lockfile_add_entry` and `merge_lock_entries` die on empty name/source instead of silently dropping
fix: `read_lockfile` dies on missing version header instead of silently parsing
fix: `_read_json_mapping` dies on malformed JSON instead of returning 0 (missing files still return 0)
fix: `classify_bump` restructured with explicit branches for all version transition types
fix: `file://` URL rejection already implemented — verified and tested
fix: lockfile replay validates store entry before symlinking (stale lockfile no longer creates broken symlinks)
fix: test infrastructure — shell tests and Pike tests can run in sequence without store pollution
fix: test counts updated to 211 shell + 342 Pike
fix: documentation hallucinations corrected — `Filesystem.Tar` is not used (system `tar` required), test counts updated
fix: `scripts/doc-sync-check.sh` updated for new module layout
fix(ci): install PUnit before running Pike tests — modules/ is gitignored and not populated on CI checkout
fix(ci): replace `Stdio.PIPE` with temp-file capture in `LockOpsAdversarialTests.pike` — `Stdio.PIPE` unavailable on CI Pike build
fix(test): convert test_outdated_no_pike_json to subprocess isolation — die() calls exit() which cannot be caught by PUnit catch blocks, killing the entire test runner process
fix(test): correct `run_pike` helper in `LockOpsAdversarialTests` — use `proc->wait()` return value for exit code instead of `proc->status()` which returns process state constant, not exit code
fix(test): use absolute path for local dep in `test_rollback_restores_local_dep` — relative `./libs/my-lib` resolved against CWD (pmp repo root) instead of temp project directory
**Error categorization** — All `die()` calls audited: integrity mismatches, store corruption, and extraction failures now exit 2 (internal error). User-facing errors remain exit 1.
**Store operations use Pike `mv()`** — Replaced three `Process.run(({"mv",...}))` calls with Pike's native `mv()`, eliminating external process dependency.
**`build_paths` uses Pike directory walk** — Replaced `find` command with recursive Pike walk for `.h` file detection, removing external dependency.
**HTTP error messages** — URLs in error messages now show only the host (not full URL) to avoid leaking tokens in logs.
**Top-level error handler** — `main()` wrapped in `catch`; unhandled exceptions produce `pmp: internal error: <msg>` with exit 2.
**Hash type consistency** — All store install methods now return `compute_dir_hash()` of the final store entry, ensuring lockfile hashes match regardless of whether the entry was cached or freshly downloaded.
**Atomic lockfile write** — Lockfile writes use Pike's `mv()` (wraps `rename(2)`) instead of `Process.run` with external `mv`.
**Temp directory** — Uses `${TMPDIR:-/tmp}` instead of hardcoded `/tmp` for temporary files.
**Store locking** — Added PID-based advisory lock on `~/.pike/store/.lock` to prevent concurrent store corruption.
**URL scheme support** — Sources can now use `https://`, `http://`, `git://`, `ssh://` prefixes and `.git` suffix, automatically stripped during normalization.
**Source URL validation** — Invalid source formats (e.g., bare names, incomplete paths) are rejected with clear error messages.
**Import scanner** — Validates dotted imports (`import Standards.JSON`), relative imports (`import .Foo`), and dotted inherits. Extracts first component for dependency matching.
**Error patterns** — Eliminated all `"unknown"` sentinel return values. Functions now return `0` on failure or `die()` for unrecoverable errors.

### Fixed

fix(security): sanitize URLs in error messages to prevent credential leakage (C-05)
fix(source): reject file:// URLs with clear error message — use local paths instead (C-07)
fix: verified SHA prefix is 16 chars (C-10), cmd_update locking is safe (C-17), cmd_remove atomicity (P-01), install rollback (H-28), cmd_rollback locking (H-29) — all confirmed already fixed
**`pmp install <url>` lockfile race condition** — Lockfile was read before acquiring the project lock, allowing concurrent installs to lose entries. Lockfile read now happens inside the locked section.
**`pmp remove` double JSON decode** — `pike.json` was decoded twice (validate + execute phases) without BOM handling. Now decoded once with `_strip_bom`, preserving raw content for rollback.
**`cmd_verify` local-source detection** — Inline `ls != "-" && !has_prefix(ls, "./") && !has_prefix(ls, "/")` replaced with `is_local_source()` helper, adding Verify.pmod to the set of modules using the shared function.
**`pmp self-update` now uses semver comparison** — comparing `0.3.0` with `0.10.0` as raw strings incorrectly reported "up to date". Uses `compare_semver()` from `Semver.pmod`.
**GitHub/GitLab tag API pagination** — `latest_tag_github` and `latest_tag_gitlab` now paginate through all tags (repos with >100 tags silently missed newer versions before).
**`compute_dir_hash` no longer uses `find`** — replaced external `find` command with Pike `get_dir` recursive walk, eliminating a vulnerability where filenames with newlines would corrupt the content hash.
**Open redirect protection in HTTP layer** — `http_get` and `http_get_safe` now validate that redirect targets stay on the same domain or a subdomain, preventing SSRF via malicious 302 responses.
**Lockfile field validation** — `write_lockfile` now rejects fields containing tab characters, which would silently corrupt the tab-separated format.

### Security

**Exit code separation** — User errors (exit 1) are now distinguishable from internal failures (exit 2). CI pipelines can differentiate between misconfiguration and bugs.
**HTTP transport hardening** — Split timeouts into connect (10s) and read (30s). Added 100 MB response body size limit to prevent OOM. Retry jitter prevents thundering herd. `Retry-After` header respected for 429 responses. Thread handles are no longer leaked on timeout.
**Store lock race fix** — Replaced TOCTOU-vulnerable `kill -0` + write with `O_EXCL` atomic create (`Stdio.File("wct")`), eliminating the window for concurrent lock acquisition.
**Streaming SHA-256** — `compute_sha256` now reads files in 64 KB chunks instead of loading entire contents into memory, preventing OOM on large packages.
**Lockfile format versioning** — Lockfiles now carry a parsed version field (`# pmp lockfile v1`). `read_lockfile` rejects future versions with a clear update suggestion.
**Lockfile newline validation** — `write_lockfile` now rejects fields containing newlines alongside tabs, preventing silent format corruption.
**`pmp remove` path traversal protection** — Module names containing `/`, `..`, or null bytes are rejected.
**install.sh checksum verification** — After pinning to a tag, the installer verifies HEAD matches the expected tag SHA, preventing MITM during clone.
**install.sh PATH modification is now opt-in** — Shell RC files are no longer modified by default. Set `PMP_MODIFY_PATH=1` to enable.
**Lockfile integrity verification** — `cmd_install_all` now compares `content_sha256` from lockfile against stored hash when installing from lockfile. Tampered or corrupted store entries are detected and rejected.
**Tarball extraction hardening** — `extract_targz` uses `--no-same-owner` flag and validates no symlink-path-traversal in extracted archives (CVE-2001-1261 class).
**HTTP timeouts** — All HTTP requests now have a 60-second timeout via thread-based timeout wrapper, preventing indefinite hangs on stalled servers.
**HTTP retry with backoff** — Transient failures (429, 5xx, connection errors) are retried up to 3 times with exponential backoff.
**Sentinel value elimination** — `resolve_commit_sha` and `compute_sha256` no longer return `"unknown"` on failure. `resolve_commit_sha` returns `0`, `compute_sha256` dies on failure. All callers updated.
**install.sh hardening** — Added `set -eu` to the installer script.
**SECURITY.md** — Added vulnerability disclosure policy with response timeline.

### Removed

Removed `Cache.pmod` — orphaned module (~140 lines) that was never wired into module.pmod or called by any other module. 18 tests (CacheAdversarialTests.pike) removed. No behavior change.

### Tests

test: `test_22_update.sh` now verifies actual version change (not just 'done' in output)
test: `test_21_changelog.sh` now includes success-path test with version comparison verification
test: `test_25_self_update.sh` now verifies exit code and output format
## [0.3.0] - 2026-04-21

### Added
- `install.sh` curl-pipe-sh installer — install pmp with `curl -LsSf https://github.com/TheSmuks/pmp/install.sh | sh`
- `pmp self-update` command — update pmp to the latest version
- `pmp rollback` command — restores all modules from `pike.lock.prev`
- `pmp changelog <module>` command — shows commit log between current and previous version
- `Semver.pmod` — semantic version parsing, comparison, and tag sorting (Pike 8.0, no external deps)
- Lockfile backup — `write_lockfile()` now copies existing lockfile to `pike.lock.prev` before overwriting
- Update summary — `pmp update` prints old→new version table with bump classification (major/minor/patch/prerelease/downgrade)
- `pmp resolve [module]` — print resolved module paths (PIKE_MODULE_PATH, PIKE_INCLUDE_PATH) or resolve a specific module to its filesystem path
- `remove` command — remove a dependency (uninstall + delete from pike.json + update lockfile)

### Fixed
- **CRITICAL: `pmp update` now replaces existing modules** — added `ctx["force"]` flag so `install_one` bypasses the version-mismatch guard during updates. Previously `pmp update` was a no-op because `install_one` would "keep existing" and return.
- **P1: Atomic lockfile writes** — `write_lockfile` now writes to a `.tmp` file and renames, preventing corruption from crashes mid-write
- **P1: Store `mv` errors are now fatal** — all three `store_install_*` functions check `mv` exit code, clean up partial entries, and die on failure instead of silently proceeding
- **P1: Lockfile source URL verification** — `lockfile_has_dep` now accepts an optional `source` parameter; `cmd_install_all` verifies source matches so changed dep URLs trigger re-resolution
- **P1: Deduplication for transitive deps in `pmp update <module>`** — extracted `merge_lock_entries()` helper using multiset-based dedup; shared by both `cmd_install` and `cmd_update`
- **P2: `pmp store prune` works when `modules/` doesn't exist** — every store entry is correctly reported as unused from the current project
- **P2: `default:` cases on unknown source types** — both switch blocks in `install_one` now die with an error for unsupported source types instead of silently falling through
- **P2: `pmp remove` warns when name not found** — tracks whether any removal occurred and warns instead of silently succeeding with exit 0
- **P2: Store reuse returns stored hash** — `read_stored_hash()` reads content hash from `.pmp-meta` instead of returning the freshly-downloaded hash (which may differ if a tag was force-pushed)
- **P2: Stale lockfile entries pruned** — `cmd_install_all` filters lockfile entries to only include deps present in `pike.json`
- **Manifest validation: comment/string stripping** — `import` statements inside `//` comments, `/* */` block comments, and `"string literals"` no longer produce false warnings
- **Manifest validation: `inherit` scanning** — `inherit Foo;` and `inherit Foo.Bar;` are now detected alongside `import Foo;`
- **Manifest validation: `#include` scanning** — `#include <Foo.pmod/bar.h>` is now recognized as a dependency indicator
- **Manifest validation: dynamic std_libs** — standard library modules are discovered from the running Pike installation instead of a hardcoded list of 32 entries
- **Manifest validation: directory recursion** — nested directories (not just `.pmod`-suffixed) are now scanned for `.pike` and `.pmod` files
- **`add_to_manifest`: false positive fix** — no longer uses raw string search; checks `data->dependencies[name]` via JSON decode to avoid false positives when the name appears in other fields like `"name"`
- `cmd_env()` now includes local path dependencies (`./` and `/` prefixed) in the generated `.pike-env/bin/pike` wrapper

### Changed
- **Breaking:** Rewrote `bin/pmp` from POSIX sh to native Pike (`bin/pmp.pike`)
  - No longer requires curl, tar, sha256sum — uses Pike's native `Protocols.HTTP`, `Standards.JSON`, `Crypto.SHA256`, `Filesystem.Tar`
  - `bin/pmp` is now a shim that delegates to `bin/pmp.pike`, sets `PIKE_MODULE_PATH`
  - JSON parsing is now native (was sed-based)
- **Refactor:** Decomposed monolithic `pmp.pike` (~1700 lines) into modular `Pmp.pmod/` library
  - 10 stateless modules: Config, Helpers, Source, Http, Resolve, Store, Lockfile, Manifest, Validate, Semver
  - Entry point `pmp.pike` (~190 lines) holds mutable state and command dispatch
  - All pure functions extracted to modules; state passed as explicit parameters
  - `store_install_*` return result mappings instead of setting globals
  - `lockfile_add_entry` returns new array (Pike arrays are immutable on `+=`)
- **Refactor:** Replaced manual argv parsing with Pike's `Arg.parse`
  - Global flags: `--help`, `--version`
  - Per-command flag parsing: `-g` in `install` and `list`
  - Subcommand args extracted via `Arg.REST`
- **Refactor:** `pmp env` now follows uv-style virtual environment patterns
  - `.pike-env/.gitignore` excludes generated files from version control
  - `pike-env.cfg` stores metadata (pike binary, project root, pmp version)
  - Wrapper reads config from `pike-env.cfg` instead of baking paths inline
  - `activate` is idempotent (guards against double-sourcing)
  - `pmp_deactivate` restores PATH, PS1, and runs `hash -r`
- **Dynamic `pmp env` wrapper** — wrapper is now fully dynamic; it reads `./modules/` at runtime instead of baking local dep paths at generation time
- **Removed `resolve_local_dep_paths()`** — `./modules/` is the single source of truth for all installed deps
- **P1: Lockfile integrity on partial store miss** — `cmd_install_all` now breaks out of lockfile loop immediately when a store entry is missing
- **P1: `pmp update <module>` preserves other lockfile entries** — single-module update merges by name instead of destroying other modules' pinned entries
- **P1: `pmp install <source>` preserves existing lockfile** — adding a new dependency merges with existing lockfile instead of overwriting
- **P2: Reproducible content hashes** — `compute_dir_hash` uses relative paths, producing identical hashes regardless of install location
- **P2: Empty lockfile writes correctly** — writes a header-only lockfile so stale lockfiles can be cleaned up
- **P2: Unknown source types die instead of returning "unknown"** — `resolve_commit_sha` calls `die()` for unrecognized source types
- **P2: Self-hosted tag resolution uses version sorting** — `git ls-remote --sort=-v:refname` with semver sort
- **P2: `lockfile_has_dep` uses explicit lockfile path** — passes `lockfile_path` as second argument
- **P2: Version mismatch still records lockfile entry** — kept version is recorded with its current metadata
- `latest_tag_github/gitlab` now returns highest semver tag instead of most-recently-created tag
- `latest_tag_selfhosted` now applies semver sort on top of `--sort=-v:refname`

### Tests
- 97 tests (was 71): added install.sh, self-update, semver parsing/comparison, lockfile backup, rollback, changelog, update summary, and error-path tests

## [0.2.0] - 2026-04-20

### Added
- `ARCHITECTURE.md` — full architecture document with diagrams, data flow, and extension points
- `RELEASE.md` — release process documentation with pre-release checklist
- `lock` command — resolve dependencies and write lockfile without installing
- `env` command — create `.pike-env/` virtual environment with `bin/pike` wrapper and `activate` script
- `run` command — execute scripts with `PIKE_MODULE_PATH` set to installed modules
- Transitive dependency resolution with cycle detection via `_VISITED`
- Manifest validation — warns on undeclared imports in installed packages
- Self-hosted git source type support
- Content-addressable store with `.pmp-meta` metadata files
- Documentation sync protocol across AGENTS.md, SKILL.md, and ARCHITECTURE.md
- CI doc-sync workflow (`.github/workflows/docs-check.yml`)
- `CHANGELOG.md` for tracking notable changes
- Conventional commit conventions documented in AGENTS.md and ARCHITECTURE.md
- `CONTRIBUTING.md` — standard contributing guide
- `.github/workflows/release.yml` — tag-triggered release workflow

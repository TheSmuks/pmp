# Changelog

All notable changes to pmp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **`pmp self-update` now uses semver comparison** — comparing `0.3.0` with `0.10.0` as raw strings incorrectly reported "up to date". Uses `compare_semver()` from `Semver.pmod`.
- **GitHub/GitLab tag API pagination** — `latest_tag_github` and `latest_tag_gitlab` now paginate through all tags (repos with >100 tags silently missed newer versions before).
- **`compute_dir_hash` no longer uses `find`** — replaced external `find` command with Pike `get_dir` recursive walk, eliminating a vulnerability where filenames with newlines would corrupt the content hash.
- **Open redirect protection in HTTP layer** — `http_get` and `http_get_safe` now validate that redirect targets stay on the same domain or a subdomain, preventing SSRF via malicious 302 responses.
- **Lockfile field validation** — `write_lockfile` now rejects fields containing tab characters, which would silently corrupt the tab-separated format.

### Added
- PUnit as a dev dependency (`pike.json`) with Pike-level unit tests (81 tests) for `Semver`, `Source`, `Lockfile`, and `Helpers` pure-function modules
- `tests/pike_tests.sh` entry point — installs PUnit and runs tests via `sh tests/pike_tests.sh`
- `tests/pike/` directory with `run.pike` harness and 4 test files: `SemverTests.pike`, `SourceTests.pike`, `LockfilePureTests.pike`, `HelpersTests.pike`
- Adopted ai-project-template v0.2.0 — added `.editorconfig`, `.gitattributes`, `.architecture.yml`, issue/PR templates, CODEOWNERS, SECURITY.md, dependabot.yml, commit-lint/changelog-check/blob-size-policy workflows, `.omp/` agent definitions, `docs/ci.md`, and ADR 0001
- Restructured test suite — split `tests/test_install.sh` (803 lines, 97 tests) into a test runner (`tests/runner.sh`) + 25 individual test files with numeric sort ordering
- `tests/helpers.sh` with extracted assertion functions and setup utilities
- `tests/test_install.sh` is now a thin shim that delegates to `tests/runner.sh`
- `pmp store prune` now deletes unused store entries (with confirmation)
- `cmd_rollback` now warns and continues on missing store entries instead of aborting
- PUnit version pinned in `pike.json` to prevent breaking CI on upstream releases

### Changed
- Updated `.gitignore` with IDE/OS/environment patterns from template
- Updated `CONTRIBUTING.md` with branch naming conventions and expanded guidelines
- Updated `README.md` with changelog badge
- Updated `AGENTS.md` with CI workflow table, agent behavior section, and template version tracking
- Rewrote `.agents/skills/pmp-dev/SKILL.md` to reflect current Pike architecture (was describing pre-0.3.0 POSIX sh implementation)
- Updated `ARCHITECTURE.md` to reflect current version (0.3.0), module list (14 modules), and line counts
- Updated `install.sh` version pin example to `v0.3.0`
- Updated `RELEASE.md` with correct syntax check command and Pike test command
- Updated `CONTRIBUTING.md` and `docs/ci.md` with Pike test commands

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

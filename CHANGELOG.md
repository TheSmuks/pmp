# Changelog

All notable changes to pmp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]


### Changed
- **Modularized pmp.pike** — extracted install orchestrators into `Pmp.Install` (390 lines), store command into `Pmp.StoreCmd` (89 lines), project commands into `Pmp.Project` (102 lines), and env/run into `Pmp.Env` (248 lines). `pmp.pike` reduced from 925 to 111 lines (config init + dispatch). Shared state now passed as a context mapping instead of global variables.

### Fixed
- **P1: Lockfile integrity on partial store miss** — `cmd_install_all` now breaks out of lockfile loop immediately when a store entry is missing, preventing duplicate lockfile entries from accumulating before re-resolution
- **P1: `pmp update <module>` preserves other lockfile entries** — single-module update now reads existing lockfile, merges the updated entry by name, and writes the combined result instead of destroying all other modules' pinned entries
- **P1: `pmp install <source>` preserves existing lockfile** — adding a new dependency now reads and merges with the existing lockfile instead of overwriting it with only the new entry
- **P2: Reproducible content hashes** — `compute_dir_hash` now uses relative paths (`find .` with cwd) instead of absolute tmpdir paths, producing identical hashes for identical content regardless of install location
- **P2: Empty lockfile writes correctly** — `write_lockfile` no longer silently skips writing when entries are empty; writes a header-only lockfile so stale lockfiles can be cleaned up
- **P2: Unknown source types die instead of returning "unknown"** — `resolve_commit_sha` now calls `die()` for unrecognized source types, matching the behavior of `latest_tag`
- **P2: Self-hosted tag resolution uses version sorting** — `latest_tag_selfhosted` now uses `git ls-remote --sort=-v:refname` (git 2.18+) and takes the first non-`^{}` line, ensuring the highest semver tag is selected instead of an arbitrary server-dependent order
- **P2: `lockfile_has_dep` uses explicit lockfile path** — passes `lockfile_path` as second argument instead of relying on default coincidence
- **P2: Version mismatch still records lockfile entry** — when installed version differs from requested, the kept version is now recorded in the lockfile with its current metadata

### Changed
- Test suite: version assertions use pattern matching (`pmp v*`) instead of literal string to avoid brittleness across version bumps
- Test suite: temp files created inside `$TESTDIR` instead of `/tmp` for proper cleanup
- Test suite: cleanup trap now does `cd /` before `rm -rf` to avoid removing wrong directory
- Test suite: inline store restore removed (EXIT trap handles it)
- Test suite: added 5 error-path tests (--version flag, unknown command, remove/run without args, install without pike.json)

### Added
- `remove` command — remove a dependency (uninstall + delete from pike.json + update lockfile)
- `CONTRIBUTING.md` — standard contributing guide
- `.github/workflows/release.yml` — tag-triggered release workflow

### Changed
- **Breaking:** Rewrote `bin/pmp` from POSIX sh to native Pike (`bin/pmp.pike`)
  - No longer requires curl, tar, sha256sum — uses Pike's native `Protocols.HTTP`, `Standards.JSON`, `Crypto.SHA256`, `Filesystem.Tar`
  - `bin/pmp` is now a shim that delegates to `bin/pmp.pike`, sets `PIKE_MODULE_PATH`
  - JSON parsing is now native (was sed-based)
  - `pmp env` resolves local dependencies at generation time instead of runtime
- **Refactor:** Decomposed monolithic `pmp.pike` (~1700 lines) into modular `Pmp.pmod/` library
  - 9 stateless modules: Config, Helpers, Source, Http, Resolve, Store, Lockfile, Manifest, Validate
  - Entry point `pmp.pike` (~480 lines) holds mutable state and command dispatch
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
- `.github/workflows/docs-check.yml` — removed `continue-on-error: true` (docs must be consistent)

### Fixed
- **Manifest validation: comment/string stripping** — `import` statements inside `//` comments, `/* */` block comments, and `"string literals"` no longer produce false warnings
- **Manifest validation: `inherit` scanning** — `inherit Foo;` and `inherit Foo.Bar;` are now detected alongside `import Foo;`
- **Manifest validation: `#include` scanning** — `#include <Foo.pmod/bar.h>` is now recognized as a dependency indicator
- **Manifest validation: dynamic std_libs** — standard library modules are discovered from the running Pike installation instead of a hardcoded list of 32 entries
- **Manifest validation: directory recursion** — nested directories (not just `.pmod`-suffixed) are now scanned for `.pike` and `.pmod` files
- **`add_to_manifest`: false positive fix** — no longer uses raw string search; checks `data->dependencies[name]` via JSON decode to avoid false positives when the name appears in other fields like `"name"`
- `cmd_env()` now includes local path dependencies (`./` and `/` prefixed) in the generated `.pike-env/bin/pike` wrapper
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

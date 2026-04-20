# AGENTS.md

## Project overview

pmp (Pike Module Package Manager) installs, versions, and resolves dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths. The architecture is a modular split: `bin/pmp.pike` (~480 lines, entry point with mutable state and command dispatch) and `bin/Pmp.pmod/` (9 stateless modules with pure functions), invoked via a POSIX sh shim `bin/pmp`.

## Setup commands

- Run all tests: `sh tests/test_install.sh`
- Verify syntax: `pike bin/pmp.pike --help`
- Check version: `pike bin/pmp.pike version` (or `sh bin/pmp version`)

Expected result: 60 passed, 0 failed, exit code 0.

## Architecture

```
bin/pmp                POSIX sh shim — sets PIKE_MODULE_PATH, delegates to pmp.pike
bin/pmp.pike           Entry point (~480 lines) — mutable state + command dispatch
bin/Pmp.pmod/          Stateless module library
  Config.pmod          PMP_VERSION constant
  Helpers.pmod         die, info, warn, need_cmd, json_field, find_project_root, compute_sha256
  Source.pmod          detect_source_type, source_to_name/version/domain/repo_path/strip_version
  Http.pmod            http_get, http_get_safe, github_auth_headers
  Resolve.pmod         latest_tag_*, resolve_commit_sha
  Store.pmod           store_entry_name, extract_targz, write_meta, compute_dir_hash, store_install_*
  Lockfile.pmod        lockfile_add_entry, write_lockfile, read_lockfile, lockfile_has_dep
  Manifest.pmod        add_to_manifest, parse_deps
  Validate.pmod        validate_manifests, strip_comments_and_strings, init_std_libs
  module.pmod          Re-exports all sub-modules via inherit
tests/test_install.sh  Test suite (pure sh, 60 tests)
README.md              User documentation
```

### Content-addressable store

Packages are downloaded once to `~/.pike/store/` with entries named `{domain}-{owner}-{repo}-{tag}-{sha_prefix_8}`. Projects symlink from `./modules/{name}/` to the store entry. Store is shared across projects — deleting `./modules/` does not affect the store.

### Lockfile (`pike.lock`)

Tab-separated, line-oriented format. Created after `pmp install` or `pmp lock`. Contains exact commit SHAs and content hashes. Should be committed to git for reproducible builds.

Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`

### Key functions

**In pmp.pike (stateful orchestrators):**
- `install_one()` — install a single dep including transitive resolution
- `cmd_install_all()` — orchestrates lockfile check, dep resolution, lockfile write

**In Pmp.pmod/ (stateless pure functions):**
- `detect_source_type()` — classifies URL as github/gitlab/selfhosted/local
- `store_entry_name()` — generates store entry name from source+tag+sha
- `store_install_*()` — download to store, compute hashes, return result mapping
- `validate_manifests()` — warn on undeclared imports/inherits/includes
- `write_lockfile()` / `read_lockfile()` — lockfile I/O (takes entries + path as params)
- `parse_deps()` — native JSON parsing via Standards.JSON
- `json_field()` — read a field from a JSON file
- `strip_comments_and_strings()` — strip comments/strings before import scanning
- `init_std_libs()` — dynamically discover stdlib modules from running Pike

- See `ARCHITECTURE.md` for full architecture document with diagrams, data flow, and extension points.

### Module design principles

- All `.pmod` modules are stateless — no mutable global variables
- State is passed explicitly as parameters (e.g., `store_dir`, `lock_entries`, `lockfile_path`)
- `lockfile_add_entry()` returns a new array (Pike `+=` creates new arrays)
- `store_install_*()` return result mappings instead of setting globals
- `module.pmod` uses `inherit .SubModule;` to re-export all symbols

## Code style

- Pike 8.0 syntax.
- Arrays: `({})`, mappings: `([])`, multisets: `(<>)`.
- 4-space indentation.
- JSON parsed natively via `Standards.JSON.decode` — no sed/awk.
- Error handling: `die("message")` exits with error to stderr.
- Info messages: `info("message")` to stdout with `pmp:` prefix.
- No external deps needed (no curl, tar, sha256sum). Pike's native `Protocols.HTTP`, `Standards.JSON`, `Crypto.SHA256`, `Filesystem.Tar` handle everything.

## Pike gotchas

- Pike's `PIKE_MODULE_PATH` is flat — any `import Foo` searches all directories
- Pike arrays: `({})`, mappings: `([])`, multisets: `(<>)`
- `compile_string` resolves `""` includes relative to source file
- pmp enforces isolation at install time (manifest validation), not at runtime
- `catch` blocks use `mixed err = catch { ... }; if (err) ...` pattern
- `inherit .Foo` in `.pmod` files copies state — shared mutable state does not work across modules. Use explicit parameter passing instead.
- `import .Foo` does not expose `protected` symbols — use `inherit .Foo` when internal access is needed, or make symbols public

## Testing instructions

- Tests are in `tests/test_install.sh` — pure sh, no framework
- Uses `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains` helpers
- Tests create temp dirs and clean up on exit
- Tests that need the store back up/restore `~/.pike/store/`
- Every change must pass all 60 tests

## Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/) 1.0.0:

```
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `style`, `revert`

Scopes: `install`, `store`, `lockfile`, `deps`, `env`, `cli`, `validate`

## Pre-commit doc checklist

| Source file changed | Must also update |
|---|---|
| `bin/pmp.pike` or `bin/Pmp.pmod/` (behavior changes) | `CHANGELOG.md`, `ARCHITECTURE.md` |
| `tests/test_install.sh` (count changes) | `CHANGELOG.md`, `AGENTS.md` (baseline) |
| `bin/pmp.pike` (new commands/flags) | `ARCHITECTURE.md`, `AGENTS.md` |
| Any source file | `CHANGELOG.md` ([Unreleased]) |

Doc-only changes do NOT trigger this checklist.

## PR instructions

- Title format: descriptive summary of the change
- Run `sh tests/test_install.sh` before committing — all 60 tests must pass
- If adding new features, add corresponding test cases

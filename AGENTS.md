# AGENTS.md

## Project overview

pmp (Pike Module Package Manager) is a native Pike script that installs, versions, and resolves dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths. The tool is `bin/pmp.pike` (~1574 lines of Pike), invoked via a 14-line `bin/pmp` shim.

## Setup commands

- Run all tests: `sh tests/test_install.sh`
- Verify syntax: `pike bin/pmp.pike --help`
- Check version: `pike bin/pmp.pike version` (or `sh bin/pmp version`)

Expected result: 51 passed, 0 failed, exit code 0.

## Architecture

```
bin/pmp                14-line POSIX sh shim — delegates to bin/pmp.pike
bin/pmp.pike           Native Pike implementation (~1574 lines)
tests/test_install.sh  Test suite (pure sh, no test framework)
README.md              User documentation
```

### Content-addressable store

Packages are downloaded once to `~/.pike/store/` with entries named `{domain}-{owner}-{repo}-{tag}-{sha_prefix_8}`. Projects symlink from `./modules/{name}/` to the store entry. Store is shared across projects — deleting `./modules/` does not affect the store.

### Lockfile (`pike.lock`)

Tab-separated, line-oriented format. Created after `pmp install` or `pmp lock`. Contains exact commit SHAs and content hashes. Should be committed to git for reproducible builds.

Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`

### Key functions

- `detect_source_type()` — classifies URL as github/gitlab/selfhosted/local
- `store_entry_name()` — generates store entry name from source+tag+sha
- `store_install_github/gitlab/selfhosted()` — download to store, compute hashes
- `install_one()` — install a single dep including transitive resolution
- `cmd_install_all()` — orchestrates lockfile check, dep resolution, lockfile write
- `validate_manifests()` — warn on undeclared imports
- `write_lockfile()` / `read_lockfile()` — lockfile I/O
- `parse_deps()` — native JSON parsing via Standards.JSON for pike.json dependencies
- `json_field()` — read a field from pike.json

- See `ARCHITECTURE.md` for full architecture document with diagrams, data flow, and extension points.

## Code style

- Pike 8.0 syntax. Use `protected` for internal members.
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

## Testing instructions

- Tests are in `tests/test_install.sh` — pure sh, no framework
- Uses `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains` helpers
- Tests create temp dirs and clean up on exit
- Tests that need the store back up/restore `~/.pike/store/`
- Every change must pass all 51 tests

## Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/) 1.0.0:

```
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `style`, `revert`

Scopes: `install`, `store`, `lockfile`, `deps`, `env`, `cli`

## Pre-commit doc checklist

| Source file changed | Must also update |
|---|---|
| `bin/pmp.pike` (behavior changes) | `CHANGELOG.md`, `ARCHITECTURE.md` |
| `tests/test_install.sh` (count changes) | `CHANGELOG.md`, `AGENTS.md` (baseline) |
| `bin/pmp.pike` (new commands/flags) | `ARCHITECTURE.md`, `AGENTS.md` |
| Any source file | `CHANGELOG.md` ([Unreleased]) |

Doc-only changes do NOT trigger this checklist.

## PR instructions

- Title format: descriptive summary of the change
- Run `sh tests/test_install.sh` before committing — all 51 tests must pass
- If adding new features, add corresponding test cases

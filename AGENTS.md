# AGENTS.md

## Project overview

pmp (Pike Module Package Manager) installs, versions, and resolves dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths. The architecture is a modular split: `bin/pmp.pike` (~185 lines, entry point with config init and command dispatch) and `bin/Pmp.pmod/` (14 sub-modules re-exported via `module.pmod`), invoked via a POSIX sh shim `bin/pmp`.

## Setup commands

- Run all tests: `sh tests/test_install.sh`
- Run Pike unit tests: `sh tests/pike_tests.sh`
- Verify syntax: `pike bin/pmp.pike --help`
- Check version: `pike bin/pmp.pike version` (or `sh bin/pmp version`)

Expected result: 114 passed, 0 failed, exit code 0 (shell tests); 81 passed for `sh tests/pike_tests.sh`.

## Architecture

```
bin/pmp                POSIX sh shim — sets PIKE_MODULE_PATH, delegates to pmp.pike
bin/pmp.pike           Entry point (~190 lines) — config init, context mapping, command dispatch
bin/Pmp.pmod/          Module library (14 modules)
  Config.pmod          PMP_VERSION constant
  Helpers.pmod         die, info, warn, need_cmd, json_field, find_project_root, compute_sha256
  Source.pmod          detect_source_type, source_to_name/version/domain/repo_path/strip_version
  Http.pmod            http_get, http_get_safe, github_auth_headers
  Resolve.pmod         latest_tag_*, resolve_commit_sha
  Store.pmod           store_entry_name, extract_targz, write_meta, compute_dir_hash, read_stored_hash, store_install_*
  Lockfile.pmod        lockfile_add_entry, write_lockfile, read_lockfile, lockfile_has_dep, merge_lock_entries
  Manifest.pmod        add_to_manifest, parse_deps
  Validate.pmod        validate_manifests, strip_comments_and_strings, init_std_libs
  Semver.pmod          parse_semver, compare_semver, sort_tags_semver, classify_bump
  Install.pmod         install_one, cmd_install, cmd_install_all, cmd_install_source, cmd_update, cmd_lock, cmd_rollback, cmd_changelog, print_update_summary
  StoreCmd.pmod        cmd_store (status + prune)
  Project.pmod         cmd_init, cmd_list, cmd_clean, cmd_remove
  Env.pmod             cmd_env, build_paths, resolve_local_dep_paths, cmd_run
  module.pmod          Re-exports all 14 sub-modules via inherit
tests/test_install.sh  Test suite (pure sh, 114 tests)
install.sh             curl-pipe-sh installer (POSIX sh)
README.md              User documentation
```

### Content-addressable store

Packages are downloaded once to `~/.pike/store/` with entries named `{domain}-{owner}-{repo}-{tag}-{sha_prefix_8}`. Projects symlink from `./modules/{name}/` to the store entry. Store is shared across projects — deleting `./modules/` does not affect the store.

### Lockfile (`pike.lock`)

Tab-separated, line-oriented format. Created after `pmp install` or `pmp lock`. Contains exact commit SHAs and content hashes. Should be committed to git for reproducible builds.

Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`

### Key functions

**In pmp.pike (dispatcher):**
- `main()` — config init, builds context mapping, Arg.parse, dispatches to command modules
- `print_help()` — usage text
- `cmd_version()` — version output
- `cmd_self_update()` — update pmp to the latest version (git fetch + tag checkout)

**In Pmp.pmod/Install.pmod (stateful orchestrators, take `mapping ctx`):**
- `install_one()` — install a single dep including transitive resolution
- `cmd_install_all()` — orchestrates lockfile check, dep resolution, lockfile write
- `cmd_install()`, `cmd_update()`, `cmd_lock()` — install-family command entry points
- `cmd_rollback()` — restore all modules from pike.lock.prev
- `cmd_changelog(args, ctx)` — show commit log between versions
- `print_update_summary(old, new)` — show old→new version table

**In Pmp.pmod/Project.pmod, StoreCmd.pmod, Env.pmod (stateful commands, take `mapping ctx`):**
- `cmd_init()`, `cmd_list()`, `cmd_clean()`, `cmd_remove()` — project management
- `cmd_store()` — store inspection and pruning
- `cmd_env()`, `build_paths()`, `cmd_run()` — environment and script execution

**In Pmp.pmod/Semver.pmod (stateless pure functions):**
- `parse_semver(tag)` — parse version string into (major, minor, patch, prerelease)
- `compare_semver(a, b)` — compare two parsed versions (-1/0/1)
- `sort_tags_semver(tags)` — sort tag strings by semver (highest first)
- `classify_bump(old, new)` — classify change as major/minor/patch/prerelease/downgrade

**In Pmp.pmod/ (stateless pure functions):**
- `detect_source_type()` — classifies URL as github/gitlab/selfhosted/local
- `store_entry_name()` — generates store entry name from source+tag+sha
- `store_install_*()` — download to store, compute hashes, return result mapping
- `read_stored_hash()` — read content_sha256 from .pmp-meta of an existing store entry
- `merge_lock_entries(existing, new)` — dedup-by-name merge using multiset; new entries replace existing with same name
- `lockfile_has_dep(name, lf, source?)` — check if dep exists in lockfile; optionally verify source URL matches
- `resolve_local_dep_paths(project_root)` — resolve local dep paths from pike.json; returns ({mod_paths, inc_paths})
- `validate_manifests()` — warn on undeclared imports/inherits/includes
- `write_lockfile()` / `read_lockfile()` — lockfile I/O (takes entries + path as params; write is atomic via tmp+rename)
- `parse_deps()` — native JSON parsing via Standards.JSON
- `json_field()` — read a field from a JSON file
- `strip_comments_and_strings()` — strip comments/strings before import scanning
- `init_std_libs()` — dynamically discover stdlib modules from running Pike

- See `ARCHITECTURE.md` for full architecture document with diagrams, data flow, and extension points.

### Module design principles

- Stateful command modules take a `mapping ctx` parameter passed by reference — mutations to `ctx["lock_entries"]` and `ctx["visited"]` are visible across calls
- Pure-function modules (Config, Helpers, Source, etc.) remain stateless — no mutable globals
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
- Every change must pass all 114 shell tests and 81 Pike unit tests

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
- Run `sh tests/test_install.sh` or `sh tests/runner.sh` before committing — all 114 tests must pass; also run `sh tests/pike_tests.sh`
- If adding new features, add corresponding test cases


## CI/CD

CI uses separate workflow files, one concern per file. See [docs/ci.md](docs/ci.md) for the full guide.

| Workflow | Purpose |
|----------|--------|
| `ci.yml` | Pike syntax check + test suite |
| `release.yml` | Create GitHub release on tag push |
| `docs-check.yml` | Verify doc sync across AGENTS.md, ARCHITECTURE.md, SKILL.md |
| `commit-lint.yml` | Conventional commit enforcement |
| `changelog-check.yml` | Require CHANGELOG.md updates on PRs |
| `blob-size-policy.yml` | Reject files >1MB on PRs |

## Agent behavior

When an AI agent is working in this repository:

1. Always create PRs for changes. Do not push directly to `main`.
2. Run available validation before requesting review: `sh tests/runner.sh` and `pike bin/pmp.pike --help`.
3. Read before editing — context above and below a match determines the correct edit.
4. Check references before renaming — use `grep` or language-server tools to find every consumer.
5. One concern per change. A PR should address one issue or feature.
6. Update documentation in the same change as code behavior changes.
7. Preserve invariants. Follow existing patterns (error handling, logging, module structure).
8. Clean up after yourself. Remove unused imports, dead code, temporary files.

## Template version

This project uses conventions from `ai-project-template` v0.2.0. See [`.template-version`](.template-version).

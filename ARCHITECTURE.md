# Architecture

## Project Identification

- **Name**: pmp (Pike Module Package Manager)
- **Repository**: github.com/TheSmuks/pmp
- **Version**: 0.2.0
- **Date**: 2026-04-20

## Project Structure

```
bin/pmp                    Single ~1233-line POSIX sh script — the entire tool
tests/test_install.sh      Test suite (pure sh, no framework, 45 tests)
AGENTS.md                  Agent context file
ARCHITECTURE.md            This file
README.md                  User documentation
LICENSE                    MIT license
pike.json                  Package manifest
.github/workflows/ci.yml   GitHub Actions CI (3 steps: install Pike, verify, test)
```

## System Diagram

```
User → pmp CLI (bin/pmp)
  │
  ├─ init         creates pike.json
  ├─ install      cmd_install_all() or cmd_install_source()
  │     │
  │     ▼
  │   parse_deps(pike.json)     → name<TAB>source lines
  │     │
  │     ▼
  │   detect_source_type(url)    → github | gitlab | selfhosted | local
  │     │
  │     ▼
  │   _install_one(name, source, target)
  │     ├─ latest_tag() / resolve_commit_sha()  → tag + SHA
  │     ├─ store_install_*()                     → download, hash, store
  │     ├─ ln -sfn STORE_DIR/entry modules/name  → symlink
  │     ├─ parse_deps(package/pike.json)          → transitive deps
  │     └─ lockfile_add_entry()                   → accumulate lockfile data
  │     │
  │     ▼
  │   write_lockfile() → pike.lock (tab-separated)
  │   validate_manifests() → warn on undeclared imports
  │
  ├─ update       removes lockfile, re-resolves
  ├─ lock         resolve + write lockfile without installing
  ├─ store        show entries / prune unused
  ├─ list         show installed modules with versions
  ├─ clean        remove ./modules/ (keeps store)
  ├─ env          create .pike-env/ virtual environment
  ├─ run          execute script with PIKE_MODULE_PATH
  └─ version      show version
```

## Core Components

### bin/pmp

Single file, all logic. Organized into sections:

- **Configuration** — version, paths, defaults
- **Helpers** — `die`, `info`, `warn`, `need_cmd`
- **JSON parsing** — `json_field`, `parse_deps` — sed-based, no jq
- **Source type detection** — `detect_source_type`, `source_to_name`/`version`/`domain`/`repo_path`
- **Store helpers** — `store_entry_name`, `compute_sha256`
- **Version resolution** — `latest_tag_github`/`gitlab`/`selfhosted`, `resolve_commit_sha`
- **Download to store** — `store_install_github`/`gitlab`/`selfhosted`
- **Lockfile I/O** — `write_lockfile`, `read_lockfile`, `lockfile_has_dep`
- **Manifest helpers** — `add_to_manifest`, `validate_manifests`
- **Transitive resolution** — `_install_one`, `_VISITED` cycle detection
- **Commands** — `cmd_init`, `cmd_install`, `cmd_install_all`, `cmd_install_source`, `cmd_update`, `cmd_lock`, `cmd_store`, `cmd_list`, `cmd_clean`, `cmd_run`, `cmd_env`
- **Main dispatch** — case statement on `$1`

### Content-addressable store

Location: `~/.pike/store/`

Entries are named `{domain}-{owner}-{repo}-{tag}-{sha_prefix8}`. Each entry contains a `.pmp-meta` file with source, tag, commit_sha, content_sha256, and installed_at. The store is shared across projects.

### Lockfile

Location: `pike.lock`

Tab-separated, line-oriented. Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`. Header comment includes version. Created after install/lock. Enables reproducible builds.

### Virtual environment

Location: `.pike-env/`

Generated `bin/pike` wrapper that sets `PIKE_MODULE_PATH` and `PIKE_INCLUDE_PATH`. `activate` script for shell sourcing.

## Data Flow — Install Lifecycle

1. User runs `pmp install` or `pmp install github.com/owner/repo`
2. If no source arg: check lockfile exists and covers all deps
3. If lockfile is complete: symlink from store entries listed in lockfile
4. Otherwise: `parse_deps(pike.json)` outputs `name<TAB>source` lines
5. For each dep: `detect_source_type` determines github/gitlab/selfhosted/local
6. For remote: resolve version (`latest_tag` or pinned `#tag`)
7. Check cycle via `_VISITED` (`type:repo_path#tag`)
8. Download to temp dir, extract, compute SHA-256
9. Move to store entry (`~/.pike/store/{slug}-{tag}-{sha8}`)
10. Write `.pmp-meta`, create symlink `./modules/{name}` → store entry
11. Check for transitive deps in installed package's `pike.json`
12. Repeat recursively for transitive deps
13. Write `pike.lock` with all resolved entries
14. `validate_manifests()` scans for undeclared imports

## Extension Points

### New source types

1. Add detection in `detect_source_type()`
2. Add `store_install_{type}()`
3. Add `latest_tag_{type}()`
4. Add `resolve_commit_sha` case

### New commands

1. Add `cmd_{name}()` function
2. Add case to main dispatch
3. Add to help text

### Lockfile format changes

1. Update `write_lockfile`/`read_lockfile`
2. Bump version comment

## Testing & CI

### GitHub Actions

Runs on `ubuntu-latest` with 3 steps:

1. Install Pike
2. Verify Pike installation
3. Run tests

### Local testing

- `sh tests/test_install.sh` — 45 tests
- `sh -n bin/pmp` — syntax check

### Test infrastructure

- Helpers: `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains`
- Tests create temp dirs via `mktemp -d`, cleanup via `trap EXIT`
- Store backup/restore pattern prevents test pollution

### Commit Conventions

This project follows [Conventional Commits](https://www.conventionalcommits.org/) 1.0.0:

```
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `style`, `revert`

Scopes: `install`, `store`, `lockfile`, `deps`, `env`, `cli`

## Glossary

- **Store entry** — Immutable directory in `~/.pike/store/` containing a downloaded package
- **Content-addressable** — Entry names include SHA prefix for uniqueness
- **Lockfile** — `pike.lock` — reproducibility artifact with exact versions and hashes
- **Manifest validation** — Warns if installed packages import modules not declared in their `pike.json` dependencies
- **Virtual environment** — `.pike-env/` — shell wrapper that injects `PIKE_MODULE_PATH`
- **Temp file pattern** — POSIX sh pattern to avoid pipe-while-read subshell issues

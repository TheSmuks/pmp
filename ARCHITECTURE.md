# Architecture

## Project Identification

- **Name**: pmp (Pike Module Package Manager)
- **Repository**: github.com/TheSmuks/pmp
- **Version**: 0.4.0
- **Date**: 2026-04-30
## Project Structure

```
bin/pmp                POSIX sh shim — delegates to bin/pmp.pike, sets PIKE_MODULE_PATH
bin/pmp.pike           Entry point (~252 lines) — config init, command dispatch
bin/Pmp.pmod/          Flat module namespace (17 modules + namespace file)
  module.pmod          Namespace-only — no inherit re-exports; sub-modules accessed as Pmp.Config etc.
  Config.pmod          PMP_VERSION constant
  Helpers.pmod         die, info, warn, need_cmd, json_field, find_project_root, compute_sha256,
                       atomic_symlink, atomic_write, sanitize_url, project_lock, project_unlock,
                       store_lock, store_unlock, advisory_lock, advisory_unlock, validate_dep_name,
                       make_temp_dir, resolve_local_path, register_cleanup_dir, run_cleanup
  Semver.pmod          parse_semver, compare_semver, sort_tags_semver, classify_bump
  Source.pmod          detect_source_type, source_to_name/version/domain/repo_path/strip_version
  Http.pmod            http_get, http_get_safe, github_auth_headers, redirect protection
                       (_url_host, _redirect_allowed_by_host), _follow_with_redirects,
                       _do_get_single, _is_private_host, SSRF helpers
  Resolve.pmod         latest_tag, latest_tag_github_safe, latest_tag_gitlab_safe,
                       latest_tag_safe, _resolve_remote, _resolve_tags,
                       resolve_commit_sha (with pagination)
  Store.pmod           store_entry_name, extract_targz, write_meta, compute_dir_hash,
                       store_install_*
  StoreCmd.pmod        cmd_store (status + prune)
  Lockfile.pmod        lockfile_add_entry, write_lockfile, read_lockfile, lockfile_has_dep
  Manifest.pmod        add_to_manifest, parse_deps
  Validate.pmod        validate_manifests, strip_comments_and_strings, init_std_libs
  Verify.pmod          cmd_verify, cmd_doctor (project and store integrity verification)
  Project.pmod         cmd_init, cmd_list, cmd_clean, cmd_remove
  Env.pmod             cmd_env, cmd_resolve, cmd_run, build_paths
                       (virtual environment, path resolution, script execution)
  Install.pmod         install_one, cmd_install, cmd_install_all, cmd_install_source,
                       project_lock/unlock (~600 lines)
  Update.pmod          cmd_update (single-module and full update), cmd_outdated,
                       print_update_summary
  LockOps.pmod         cmd_lock, cmd_rollback, cmd_changelog
                       — lockfile operations and version comparison
docs/
  TIGER_STYLE.md       TigerBeetle coding style guide (reference for project conventions)
tests/pike_tests.sh     Entry point for Pike unit tests (installs PUnit, runs tests/pike/run.pike)
tests/pike/             PUnit test files (SemverTests, SourceTests, LockfilePureTests,
                         HelpersTests, StoreCmdAdversarialTests)
tests/test_install.sh   Shell integration test suite (172 tests)
```

## Module Resolution

The shell shim (`bin/pmp`) sets a single `PIKE_MODULE_PATH` pointing at `bin/`. Pike resolves `import Pmp.Config` as `bin/Pmp.pmod/Config.pmod`. Sub-modules use sibling imports (`import .Helpers;`) to reference other modules in the same directory. The `module.pmod` file is a namespace placeholder — it contains no inherit re-exports; all modules are accessed directly via their qualified names (e.g., `Pmp.Config`, `Pmp.Store`).

## System Diagram

```
User → pmp CLI (bin/pmp shim → bin/pmp.pike)
  │
  ├─ init         creates pike.json
  ├─ install      cmd_install_all() or cmd_install_source()
  │     │
  │     ▼
  │   parse_deps(pike.json)     → name<TAB>source lines
  │     │                        (native Standards.JSON.decode)
  │     ▼
  │   detect_source_type(url)    → github | gitlab | selfhosted | local
  │     │
  │     ▼
  │   install_one(name, source, target)
  │     ├─ latest_tag() / resolve_commit_sha()  → tag + SHA
  │     ├─ store_install_*()                     → download, hash, store
  │     │                                        (Protocols.HTTP,
  │     │                                         Crypto.SHA256,
  │     │                                         system tar via Process.run)
  │     ├─ symlink STORE_DIR/entry → modules/name
  │     ├─ parse_deps(package/pike.json)          → transitive deps
  │     └─ lockfile_add_entry()                   → accumulate lockfile data
  │     │
  │     ▼
  │   write_lockfile() → pike.lock (tab-separated)
  │   validate_manifests() → warn on undeclared imports
  │
  ├─ update       removes lockfile, re-resolves, shows summary table
  ├─ rollback     restore modules from pike.lock.prev
  ├─ changelog    show commit log between versions
  ├─ lock         resolve + write lockfile without installing
  ├─ store        show entries / prune unused
  ├─ list         show installed modules with versions
  ├─ remove       remove a module and its store entry
  ├─ clean        remove ./modules/ (keeps store)
  ├─ env          create .pike-env/ virtual environment (dynamic wrapper)
  ├─ resolve      print PIKE_MODULE_PATH/PIKE_INCLUDE_PATH or resolve a module name
  ├─ run          execute script with PIKE_MODULE_PATH
  ├─ self-update  update pmp to the latest version
  └─ version      show version
```

## Core Components

### bin/pmp.pike (entry point, ~252 lines)

Holds all mutable state (`lock_entries`, `visited`, `std_libs`, config paths) and command dispatch. All pure functions are imported from `Pmp.pmod/` via explicit imports (`import Pmp.Config;`, `import Pmp.Helpers;`, etc.).

- **Configuration** — `pike_bin`, `global_dir`, `local_dir`, `store_dir`, `pike_json`, `lockfile_path`
- **Mutable state** — `lock_entries` array, `visited` multiset, `std_libs` multiset
- **Transitive resolution** — `install_one()` orchestrates Store, Resolve, Lockfile modules
- **Commands** — `cmd_init`, `cmd_install`, `cmd_install_all`, `cmd_install_source`, `cmd_update`, `cmd_rollback`, `cmd_changelog`, `cmd_lock`, `cmd_store`, `cmd_list`, `cmd_clean`, `cmd_remove`, `cmd_run`, `cmd_env`, `cmd_resolve`
- **Main dispatch** — `switch (argv[1])`

### bin/Pmp.pmod/ (module library, 17 modules, flat layout)

All modules are pure functions — no mutable global state. State is passed as explicit parameters. All 17 modules live as flat `.pmod` files under `bin/Pmp.pmod/`. `module.pmod` is namespace-only (no inherit re-exports).

#### Config & Utilities

- **Config.pmod** — `PMP_VERSION` constant
- **Helpers.pmod** — `die`, `info`, `warn`, `need_cmd`, `json_field`, `find_project_root`, `compute_sha256`, `atomic_symlink`, `atomic_write`, `sanitize_url`, `project_lock`/`project_unlock`, `store_lock`/`store_unlock`, `advisory_lock`/`advisory_unlock`, `validate_dep_name`, `make_temp_dir`, `resolve_local_path`, `register_cleanup_dir`, `run_cleanup`
- **Semver.pmod** — `parse_semver`, `compare_semver`, `sort_tags_semver`, `classify_bump`
- **Source.pmod** — `detect_source_type`, `source_to_name`/`version`/`domain`/`repo_path`/`strip_version`

#### Network

- **Http.pmod** — `http_get`, `http_get_safe`, `github_auth_headers`, redirect protection (`_url_host`, `_redirect_allowed_by_host`), `_follow_with_redirects`, `_do_get_single`, `_is_private_host`, SSRF helpers
- **Resolve.pmod** — `latest_tag`, `latest_tag_github_safe`, `latest_tag_gitlab_safe`, `latest_tag_safe`, `_resolve_remote`, `_resolve_tags`, `resolve_commit_sha` (with pagination)

#### Content-addressable store

- **Store.pmod** — `store_entry_name`, `extract_targz` (uses system `tar` via `Process.run`), `write_meta`, `compute_dir_hash`, `store_install_*` (return result mappings)
- **StoreCmd.pmod** — `cmd_store` (status + prune)

#### Project operations

- **Lockfile.pmod** — `lockfile_add_entry` (returns new array), `write_lockfile`, `read_lockfile`, `lockfile_has_dep`
- **Manifest.pmod** — `add_to_manifest`, `parse_deps`
- **Validate.pmod** — `validate_manifests`, `strip_comments_and_strings`, `init_std_libs`
  - Strips `//` and `/* */` comments and string/char literals before scanning
  - Scans `import`, `inherit`, and `#include <Foo.pmod/...>` statements
  - Recurses into all nested directories (not just `.pmod`-suffixed)
  - Builds `std_libs` dynamically from the running Pike's module path
- **Verify.pmod** — `cmd_verify`, `cmd_doctor` (project and store integrity verification)
- **Project.pmod** — `cmd_init`, `cmd_list`, `cmd_clean`, `cmd_remove`
- **Env.pmod** — `cmd_env`, `cmd_resolve`, `cmd_run`, `build_paths` (virtual environment, path resolution, script execution)

#### Install & update orchestrators

- **Install.pmod** — `install_one`, `cmd_install`, `cmd_install_all`, `cmd_install_source`, `project_lock`/`project_unlock` (shared lock helpers, ~600 lines)
- **Update.pmod** — `cmd_update` (single-module and full update with lock management), `cmd_outdated` (compares lockfile versions with latest remote tags), `print_update_summary`
- **LockOps.pmod** — `cmd_lock` (resolve + write lockfile without installing), `cmd_rollback` (restore modules from pike.lock.prev), `cmd_changelog` (show commit log between versions via GitHub/GitLab compare APIs)

### Content-addressable store

Location: `~/.pike/store/`

Entries are named `{domain}-{owner}-{repo}-{tag}-{sha_prefix16}`. Each entry contains a `.pmp-meta` file with source, tag, commit_sha, content_sha256, and installed_at. The store is shared across projects.

### Lockfile

Location: `pike.lock`

Tab-separated, line-oriented. Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`. Header comment includes version. Created after install/lock. Enables reproducible builds.

### Virtual environment

Location: `.pike-env/`

Generated `bin/pike` wrapper that sets `PIKE_MODULE_PATH` and `PIKE_INCLUDE_PATH`. Wrapper is fully dynamic — reads `./modules/` at runtime, no baked paths. `activate` script for shell sourcing. `cmd_resolve` prints resolved paths or resolves a specific module name to its filesystem path.

## Data Flow — Install Lifecycle

1. User runs `pmp install` or `pmp install github.com/owner/repo`
2. If no source arg: check lockfile exists and covers all deps
3. If lockfile is complete: symlink from store entries listed in lockfile
4. Otherwise: `parse_deps(pike.json)` uses `Standards.JSON.decode` natively → `name<TAB>source` lines
5. For each dep: `detect_source_type` determines github/gitlab/selfhosted/local
6. For remote: resolve version (`latest_tag` or pinned `#tag`)
7. Check cycle via `visited` multiset (`source:repo_path#tag`)
8. Download via `Protocols.HTTP`, hash via `Crypto.SHA256`, extract via system `tar` (`Process.run`)
9. Move to store entry (`~/.pike/store/{slug}-{tag}-{sha16}`)
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

- `sh tests/test_install.sh` — 208 shell tests + 330 Pike unit tests (`tests/pike_tests.sh`)

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

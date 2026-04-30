# AGENTS.md

## Project overview

pmp (Pike Module Package Manager) installs, versions, and resolves dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths. The architecture is a modular split: `bin/pmp.pike` (~252 lines, entry point with config init, error handling, and command dispatch) and a layered module library under `bin/` (17 functional modules across 5 domain directories + 1 aggregator), invoked via a POSIX sh shim `bin/pmp` that sets `PIKE_MODULE_PATH` to include all subdirectories.

## Setup commands

- Run all tests: `sh tests/test_install.sh`
- Run Pike unit tests: `sh tests/pike_tests.sh`
- Verify syntax: `pike bin/pmp.pike --help`
- Check version: `pike bin/pmp.pike version` (or `sh bin/pmp version`)

Expected result: 174 passed, 0 failed, exit code 0 (shell tests via `sh tests/runner.sh`); 317 passed for `sh tests/pike_tests.sh`.

## Architecture

```
bin/pmp                POSIX sh shim — sets PIKE_MODULE_PATH to include all layer directories, delegates to pmp.pike
bin/pmp.pike           Entry point (~251 lines) — config init, context mapping, command dispatch

bin/core/              Pure-function layer (no network, no I/O side effects)
  Config.pmod          PMP_VERSION constant; EXIT_OK/EXIT_ERROR/EXIT_INTERNAL exit codes; PMP_VERBOSE/PMP_QUIET variables
  Helpers.pmod         die, die_internal, info, warn, debug, need_cmd, json_field, find_project_root, compute_sha256 (streaming), sanitize_url, project_lock/unlock, store_lock/unlock
  Semver.pmod          parse_semver, compare_semver, sort_tags_semver, classify_bump
  Source.pmod          detect_source_type, source_to_name/version/domain/repo_path/strip_version

bin/transport/         Network layer
  Http.pmod            http_get, http_get_safe, github_auth_headers; retry with jitter, Retry-After, split connect/read timeouts, body size limit
  Resolve.pmod         latest_tag_*, resolve_commit_sha

bin/store/             Content-addressable store layer
  Store.pmod           store_entry_name, extract_targz, write_meta, compute_dir_hash, read_stored_hash, store_install_*; O_EXCL lock, Pike mv()
  StoreCmd.pmod        cmd_store (status + prune)

bin/project/           Project operations layer
  Lockfile.pmod        lockfile_add_entry, write_lockfile, read_lockfile, lockfile_has_dep, merge_lock_entries; LOCKFILE_VERSION, tab/newline validation
  Manifest.pmod        add_to_manifest, parse_deps
  Validate.pmod        validate_manifests — warn on undeclared imports/inherits/includes
  Verify.pmod          Project and store integrity verification (~259 lines). Functions: cmd_verify(mapping ctx)→int, cmd_doctor(mapping ctx)→int.
  Project.pmod         cmd_init (write verification), cmd_list (column headers), cmd_clean (summary), cmd_remove (path traversal protection)
  Env.pmod             cmd_env, build_paths, cmd_run, cmd_resolve (Pike-native _has_headers)

bin/commands/          Stateful orchestrator layer (take mapping ctx)
  Install.pmod         install_one, cmd_install, cmd_install_all, cmd_install_source
  Update.pmod          Update and outdated commands (~200 lines). Functions: cmd_update, cmd_outdated, print_update_summary.
  LockOps.pmod         Lock, rollback, and changelog commands (~280 lines). Functions: cmd_lock, cmd_rollback, cmd_changelog.

bin/Pmp.pmod/          Aggregator
  module.pmod          Inherits all 17 sub-modules using flat names (resolved via PIKE_MODULE_PATH)

tests/test_install.sh  Test suite (pure sh, delegates to runner.sh)
install.sh             curl-pipe-sh installer (POSIX sh)
README.md              User documentation
docs/TIGER_STYLE.md    TigerBeetle coding style guide — principles adopted in Code Style section below
```

### Content-addressable store

Packages are downloaded once to `~/.pike/store/` with entries named `{domain}-{owner}-{repo}-{tag}-{sha_prefix_8}`. Projects symlink from `./modules/{name}/` to the store entry. Store is shared across projects — deleting `./modules/` does not affect the store.

### Lockfile (`pike.lock`)

Tab-separated, line-oriented format. Created after `pmp install` or `pmp lock`. Contains exact commit SHAs and content hashes. Should be committed to git for reproducible builds.

Format: `name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256`

### Key functions

**In pmp.pike (dispatcher):**
- `main()` — config init, builds context mapping, Arg.parse, dispatches to command modules. Top-level catch for unhandled exceptions (exit 2).
- `print_help()` — usage text
- `cmd_version()` — version output
- `cmd_self_update()` — update pmp to the latest version (git fetch + tag checkout)

**In commands/Install.pmod (stateful install orchestrators, take `mapping ctx`):
- `install_one()` — install a single dep including transitive resolution
- `cmd_install_all()` — orchestrates lockfile check, dep resolution, lockfile write
- `cmd_install()`, `cmd_install_source()` — install-family command entry points

**In commands/Update.pmod (stateful commands, take `mapping ctx`):
- `cmd_update()` — update dependencies to latest versions
- `cmd_outdated()` — list dependencies with newer versions available
- `print_update_summary(old, new)` — show old→new version table

**In commands/LockOps.pmod (stateful commands, take `mapping ctx`):
- `cmd_lock()` — lock dependencies at current versions
- `cmd_rollback()` — restore all modules from pike.lock.prev
- `cmd_changelog(args, ctx)` — show commit log between versions

**In project/Project.pmod, store/StoreCmd.pmod, project/Env.pmod (stateful commands, take `mapping ctx`):
- `cmd_init()`, `cmd_list()`, `cmd_clean()`, `cmd_remove()` — project management
- `cmd_store()` — store inspection and pruning
- `cmd_env()`, `build_paths()`, `cmd_run()` — environment and script execution

**In project/Verify.pmod (stateful commands, take `mapping ctx`):
- `cmd_verify(ctx)` — verify project integrity (lockfile vs store vs modules consistency check)
- `cmd_doctor(ctx)` — diagnose common issues (missing store entries, broken symlinks, stale lockfile)

**In core/Semver.pmod (stateless pure functions):
- `parse_semver(tag)` — parse version string into (major, minor, patch, prerelease)
- `compare_semver(a, b)` — compare two parsed versions (-1/0/1)
- `sort_tags_semver(tags)` — sort tag strings by semver (highest first)
- `classify_bump(old, new)` — classify change as major/minor/patch/prerelease/downgrade

**In core/, transport/, store/, project/ (stateless pure functions):
- `detect_source_type()` — classifies URL as github/gitlab/selfhosted/local
- `store_entry_name()` — generates store entry name from source+tag+sha
- `store_install_*()` — download to store, compute hashes, return result mapping
- `read_stored_hash()` — read content_sha256 from .pmp-meta of an existing store entry
- `merge_lock_entries(existing, new)` — dedup-by-name merge using multiset; new entries replace existing with same name
- `lockfile_has_dep(name, lf, source?)` — check if dep exists in lockfile; optionally verify source URL matches
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
- `module.pmod` uses flat `inherit SubModule;` (no dot prefix) — modules are resolved via `PIKE_MODULE_PATH` which the sh shim sets to include all layer directories

## Code style

- Pike 8.0 syntax.
- Arrays: `({})`, mappings: `([])`, multisets: `(<>)`.
- 4-space indentation.
- JSON parsed natively via `Standards.JSON.decode` — no sed/awk.
- Error handling: `die("message")` exits with error to stderr.
- Info messages: `info("message")` to stdout with `pmp:` prefix.
- No external deps needed (no curl, tar, sha256sum). Pike's native `Protocols.HTTP`, `Standards.JSON`, `Crypto.SHA256`, `Filesystem.Tar` handle everything.

### Tiger Style (adopted from [TigerBeetle](docs/TIGER_STYLE.md))

The TigerBeetle coding style guide informs our approach. Key principles adapted for Pike:

**Safety:**
- Use only very simple, explicit control flow. Do not use recursion — all executions that should be bounded must be bounded.
- Put a limit on everything. All loops must have a fixed upper bound to prevent infinite loops or tail latency spikes.
- Assert all function arguments, return values, preconditions, postconditions, and invariants. The assertion density must average a minimum of two assertions per function.
- Pair assertions: for every property you enforce, find at least two different code paths where an assertion can be added.
- Split compound assertions: prefer `assert(a); assert(b);` over `assert(a && b);`.
- Assert the positive space you expect AND the negative space you do not expect. Where data moves across the valid/invalid boundary is where bugs are found.
- All errors must be handled. Do not silently swallow errors — every `catch` block must either handle, rethrow, or explicitly log.
- Always motivate, always say why. Comments explain the rationale for decisions, not just what the code does.

**Simplicity:**
- Simplicity is how we bring design goals together. The "super idea" solves the axes simultaneously.
- Simplicity is not the first attempt but the hardest revision. Expect multiple passes.
- Zero technical debt: solve problems when you find them. The second time may not transpire.
- Declare variables at the smallest possible scope. Minimize the number of variables in scope.
- Hard limit of 70 lines per function. If a function doesn't fit on a screen, split it. Good splits centralize control flow in the parent and move non-branchy logic to helpers. Push `if`s up and `for`s down.
- Don't duplicate variables or take aliases to them. This reduces the probability that state gets out of sync.

**Naming:**
- Get the nouns and verbs just right. Great names capture what a thing is or does and provide a crisp mental model.
- Do not abbreviate variable names. Use long-form flags: `--force`, not `-f`.
- When choosing related names, try to find names with the same number of characters so they line up. `source` and `target` are better than `src` and `dest`.
- Add units or qualifiers to variable names, put them last sorted by descending significance: `latency_ms_max` not `max_latency_ms`.
- Order matters. Put important things near the top. The `main` function goes first.

**Performance:**
- Think about performance from the outset. The best time to get the huge wins is in the design phase, when you can't measure or profile.
- Perform back-of-the-envelope sketches with respect to the four resources (network, disk, memory, CPU) and their two main characteristics (bandwidth, latency).
- Optimize for the slowest resources first: network, disk, memory, CPU — in that order.
- Amortize costs by batching accesses.
- Be explicit. Minimize dependence on the compiler to do the right thing.

## Pike gotchas

- Pike's `PIKE_MODULE_PATH` is flat — any `import Foo` searches all directories
- Pike arrays: `({})`, mappings: `([])`, multisets: `(<>)`
- `compile_string` resolves `""` includes relative to source file
- pmp enforces isolation at install time (manifest validation), not at runtime
- `catch` blocks use `mixed err = catch { ... }; if (err) ...` pattern
- `inherit .Foo` in `.pmod` files copies state — shared mutable state does not work across modules. Use explicit parameter passing instead. In the new layout, inherit lines use flat names (e.g., `inherit Config;`) resolved via `PIKE_MODULE_PATH`.
- `import .Foo` does not expose `protected` symbols — use `inherit .Foo` when internal access is needed, or make symbols public

## Testing instructions

- Tests are in `tests/test_install.sh` — pure sh, no framework
- Uses `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains` helpers
- Tests create temp dirs and clean up on exit
- Tests that need the store back up/restore `~/.pike/store/`
- Every change must pass all 174 shell tests and 317 Pike unit tests

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
- Run `sh tests/test_install.sh` or `sh tests/runner.sh` before committing — all 174 tests must pass; also run `sh tests/pike_tests.sh`
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

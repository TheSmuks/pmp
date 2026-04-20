# AGENTS.md

## Project overview

pmp (Pike Module Package Manager) is a POSIX sh script that installs, versions, and resolves dependencies for Pike modules. It works with GitHub, GitLab, self-hosted git, and local paths. The entire tool is a single `bin/pmp` script (~1200 lines of POSIX sh).

## Setup commands
- Run all tests: `sh tests/test_install.sh`
- Verify syntax: `sh -n bin/pmp`
- Check version: `sh bin/pmp version`

Expected result: 45 passed, 0 failed, exit code 0.

## Architecture

```
bin/pmp                    # Single POSIX sh script — the entire tool
tests/test_install.sh      # Test suite (pure sh, no test framework)
README.md                  # User documentation
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
- `_install_one()` — install a single dep including transitive resolution
- `cmd_install_all()` — orchestrates lockfile check, dep resolution, lockfile write
- `validate_manifests()` — warn on undeclared imports in installed packages
- `write_lockfile()` / `read_lockfile()` — lockfile I/O
- `parse_deps()` — sed-based JSON parser for `pike.json` dependencies

- See `ARCHITECTURE.md` for full architecture document with diagrams, data flow, and extension points
## Code style
- POSIX sh only (dash-compatible). No bashisms: no `[[`, no arrays, no `$()`.
  - Actually `$()` is fine in POSIX sh. Avoid `[[` and `(( ))`.
- 2-space indentation.
- No jq dependency — JSON is parsed with sed/awk.
- Use `(|)` as sed delimiter for URLs containing `/`.
- Temp files for pipe-while-read patterns (POSIX sh doesn't support pipe-while-read reliably with variables).
- `$(...)` for command substitution, not backticks.
- Error handling: `die "message"` exits with error to stderr.
- Info messages: `info "message"` to stdout with `pmp:` prefix.

## POSIX sh gotchas
- `while read` in a pipe runs in a subshell — variables set inside are lost. Use temp file pattern: `parse_deps > "$_tmpfile"; while read ... done < "$_tmpfile"`.
- `sed -i` is not POSIX but works on Linux (GNU sed). Acceptable for this project.
- `local` is not POSIX but widely supported. Use `avoid by convention` — prefix internal vars with `_` instead.
- `set -e` with functions: functions returning non-zero exit status will trigger exit. Use `|| true` for expected failures.
- No `realpath` on all systems. Use `readlink -f` on Linux, or `cd dir && pwd` pattern.

## Pike-specific context
- Pike's `PIKE_MODULE_PATH` is flat — any `import Foo` searches all directories
- Pike arrays: `({})`, mappings: `([])`, multisets: `(<>)`
- `compile_string` resolves `""` includes relative to source file
- pmp enforces isolation at install time (manifest validation), not at runtime

## Testing instructions
- Tests are in `tests/test_install.sh` — pure sh, no framework
- Uses `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains` helpers
- Tests create temp dirs and clean up on exit
- Tests that need the store back up/restore `~/.pike/store/`
- Every change must pass all 45 tests

## PR instructions
- Title format: descriptive summary of the change
- Run `sh tests/test_install.sh` before committing — all tests must pass
- If adding new features, add corresponding test cases
- Verify syntax with `sh -n bin/pmp`

# pmp-dev

Develop and modify the pmp package manager itself.

## When to use

Editing `bin/pmp`, `tests/test_install.sh`, or any pmp infrastructure. Use when fixing pmp bugs, adding commands, changing install behavior, or updating the store/lockfile model.

## Architecture

pmp is a single ~1200-line POSIX sh script at `bin/pmp`. There is no build step. Tests are in `tests/test_install.sh` using custom assert helpers.

### Content-addressable store model

```
~/.pike/store/
  github.com-thesmuks-punit-v1.0.0-a1b2c3d4/   # immutable store entry
    .pmp-meta                                     # metadata (source, tag, sha, hash)
    PUnit.pmod/
    pike.json
```

Projects symlink: `./modules/PUnit -> ~/.pike/store/github.com-thesmuks-punit-v1.0.0-a1b2c3d4/`

### Lockfile format

```
# pmp lockfile v1 — DO NOT EDIT
# name  source  tag  commit_sha  content_sha256
PUnit   github.com/thesmuks/punit-tests  v1.0.0  a1b2c3...  abcd1234...
```

Tab-separated. Created by `pmp install` or `pmp lock`. Read by `cmd_install_all()` to skip resolution.

## Key patterns

### JSON parsing (no jq)

```sh
# Read a field from pike.json
json_field "name" "pike.json"

# Parse all dependencies: outputs name<TAB>source lines
parse_deps "pike.json"
```

Both use sed with `"` delimited patterns. The parser is line-by-line — it tracks `_in_deps` state to know when inside the dependencies block.

### URL handling

```sh
# sed delimiter must be | not / when processing URLs
sed 's|/|%2F|g'   # NOT sed 's/\//%2F/g'

# Source type detection via URL pattern
detect_source_type "github.com/owner/repo"  # → github
detect_source_type "./libs/foo"              # → local
```

### Temp file pattern (not pipe-while-read)

```sh
# WRONG — subshell loses variables:
parse_deps | while read name src; do
  count=$((count + 1))  # lost when subshell exits
done

# CORRECT — temp file:
_tmpfile="$(mktemp)"
parse_deps > "$_tmpfile"
while IFS='	' read -r _name _src; do
  ...
done < "$_tmpfile"
rm -f "$_tmpfile"
```

### Install flow

1. `cmd_install` / `cmd_install_all` — entry point
2. `_install_one(name, source, target)` — install one dep
   - Detects source type
   - For remote: calls `store_install_*()` to download to store
   - Symlinks from `./modules/` to store entry
   - Checks for transitive deps in installed package's `pike.json`
   - Records entry for lockfile
3. `write_lockfile()` — writes accumulated entries
4. `validate_manifests()` — scans for undeclared imports

### Store entry naming

```sh
store_entry_name "github.com/thesmuks/punit-tests" "v1.0.0" "a1b2c3d4..."
# → "github.com-thesmuks-punit-tests-v1.0.0-a1b2c3d4"
```

Format: `{domain}-{owner}-{repo}-{tag}-{sha_prefix_8}`. Path slashes become dashes.

### Cycle detection

`_VISITED` tracks `type:repo_path#tag` entries. Before installing, check if already visited. Prevents infinite loops in transitive deps.

## POSIX sh constraints

- No bashisms: no `[[`, no arrays, no `local` keyword (use `_` prefix convention)
- `set -e` — any non-zero exit is fatal. Use `|| true` for expected failures
- No `realpath` — use `readlink -f` or `cd dir && pwd`
- `sed -i` works on Linux (GNU sed) but is not strictly POSIX
- Heredocs with `<< 'WORD'` (quoted) prevent variable expansion

## Running tests

```sh
sh tests/test_install.sh          # All tests
sh -n bin/pmp                      # Syntax check only
```

Expected: 45 passed, 0 failed.

Tests create temp dirs via `mktemp -d` and clean up via `trap cleanup EXIT`. The store backup/restore pattern prevents tests from polluting the real `~/.pike/store/`.

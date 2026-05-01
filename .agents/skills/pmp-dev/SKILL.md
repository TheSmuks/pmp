# pmp-dev

Develop and modify the pmp package manager (Pike 8.0).

## When to use

Editing `bin/pmp.pike`, `bin/Pmp.pmod/*.pmod`, `tests/`, or any pmp infrastructure. Use when fixing pmp bugs, adding commands, changing install behavior, or updating the store/lockfile model.

## Architecture

pmp is a Pike 8.0 application (~4672 lines across 18 module files + 274-line entry point).

- `bin/pmp` — POSIX sh shim that sets `PIKE_MODULE_PATH` and delegates to `pike -M bin bin/pmp.pike`
- `bin/pmp.pike` — Entry point: config init, command dispatch, argument parsing
- `bin/Pmp.pmod/` — Library of 17 functional + 1 namespace Pike module (18 total):
  - `module.pmod` — Re-exports all sub-modules via `inherit`
  - `Config.pmod` — `PMP_VERSION` constant
  - `Helpers.pmod` — `die`, `info`, `warn`, `need_cmd`, `json_field`, `find_project_root`, `compute_sha256`
  - `Source.pmod` — `detect_source_type`, `source_to_name/version/domain/repo_path/strip_version`
  - `Http.pmod` — `http_get`, `http_get_safe`, `github_auth_headers`, `_url_host`, `_redirect_allowed_by_host`
  - `Resolve.pmod` — `latest_tag_github/gitlab/selfhosted`, `resolve_commit_sha` (with pagination)
  - `Store.pmod` — `store_entry_name`, `extract_targz`, `write_meta`, `compute_dir_hash`, `store_install_*`, `resolve_module_path`, `_collect_files`
  - `Lockfile.pmod` — `lockfile_add_entry`, `write_lockfile`, `read_lockfile`, `lockfile_has_dep`, `merge_lock_entries`
  - `Manifest.pmod` — `add_to_manifest`, `parse_deps`
  - `Validate.pmod` — `validate_manifests`, `strip_comments_and_strings`, `init_std_libs`
  - `Semver.pmod` — `parse_semver`, `compare_semver`, `sort_tags_semver`, `classify_bump`
  - `Install.pmod` — `install_one`, `cmd_install`, `cmd_install_all`, `cmd_install_source`
  - `Update.pmod` — `cmd_update`, `print_update_summary`
  - `LockOps.pmod` — `cmd_lock`, `cmd_rollback`, `cmd_changelog`
  - `Project.pmod` — `cmd_init`, `cmd_list`, `cmd_clean`, `cmd_remove`
  - `StoreCmd.pmod` — `cmd_store` (status + prune)
  - `Env.pmod` — `cmd_env`, `build_paths`, `cmd_run`, `cmd_resolve`
  - `Verify.pmod` — store and dependency verification

## Key patterns

### JSON parsing

```pike
// Native — no sed, no awk, no jq
mapping data = Standards.JSON.decode(Stdio.read_file("pike.json"));
string name = data->name;
mapping deps = data->dependencies || ([]);
```

### HTTP requests

```pike
// GitHub API call with optional auth
mapping headers = github_auth_headers();
Protocols.HTTP.Query q = Protocols.HTTP.do_method("GET", url, 0, headers);
if (q->status != 200) die("HTTP " + q->status + ": " + url);
```

### Error handling and output

```pike
die("msg");   // exits with error, prints to stderr
info("msg");  // prints to stdout
warn("msg");  // prints to stderr, does not exit
```

### Command functions

Stateful commands take `mapping ctx` by reference; pure utility functions are stateless.

```pike
void cmd_install(mapping ctx) { ... }        // receives context with config, args
string compute_sha256(string path) { ... }   // pure function, no ctx
```

### Module design

`inherit .Foo` copies state — shared mutable state does not work across modules. Use explicit parameter passing instead.

## Content-addressable store

```
~/.pike/store/
  github.com-thesmuks-punit-v1.0.0-a1b2c3d4/   # immutable store entry
    .pmp-meta                                     # metadata (source, tag, sha, hash)
    PUnit.pmod/
    pike.json
```

Projects symlink: `./modules/PUnit -> ~/.pike/store/github.com-thesmuks-punit-v1.0.0-a1b2c3d4/`

Store entry name format: `{domain}-{owner}-{repo}-{tag}-{sha_prefix16}`. Path slashes become dashes.

## Lockfile format

```
# pmp lockfile v1 — DO NOT EDIT
# name  source  tag  commit_sha  content_sha256
PUnit   github.com/thesmuks/punit-tests  v1.0.0  a1b2c3...  abcd1234...
```

Tab-separated. Created by `pmp install` or `pmp lock`. Read by `cmd_install_all()` to skip resolution.

## Running tests

```sh
sh tests/runner.sh              # 208 shell tests across test_01–test_26
sh tests/test_install.sh        # same runner (legacy alias)
sh tests/pike_tests.sh          # 330 Pike unit tests (PUnit-based)
sh bin/pmp --help               # syntax check — validates Pike compilation
```

Tests use `assert`, `assert_exists`, `assert_not_exists`, `assert_output_contains` helpers from `tests/helpers.sh`. Shell tests create temp dirs via `mktemp -d` and clean up via `trap cleanup EXIT`. The store backup/restore pattern prevents tests from polluting the real `~/.pike/store/`.

## Pike gotchas

- Pike's `PIKE_MODULE_PATH` is flat — any `import Foo` searches all directories
- Pike arrays: `({})`, mappings: `([])`, multisets: `(<>)`
- `compile_string` resolves `""` includes relative to source file
- pmp enforces isolation at install time (manifest validation), not at runtime
- `catch` blocks use `mixed err = catch { ... }; if (err) ...` pattern
- `inherit .Foo` in `.pmod` files copies state — shared mutable state does not work across modules. Use explicit parameter passing instead.
- `import .Foo` does not expose `protected` symbols — use `inherit .Foo` when internal access is needed, or make symbols public

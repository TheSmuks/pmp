# pmp — Pike Module Package Manager

[![CI](https://github.com/TheSmuks/pmp/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSmuks/pmp/actions/workflows/ci.yml)
[![Release](https://github.com/TheSmuks/pmp/actions/workflows/release.yml/badge.svg)](https://github.com/TheSmuks/pmp/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/TheSmuks/pmp?label=version&color=brightgreen)](https://github.com/TheSmuks/pmp/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Changelog](https://img.shields.io/badge/changelog-Keep%20a%20Changelog-blue.svg)](./CHANGELOG.md)

Install, version, and resolve dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths.

## Installation

```bash
curl -LsSf https://github.com/TheSmuks/pmp/install.sh | sh
```

Or with wget:

```bash
wget -qO- https://github.com/TheSmuks/pmp/install.sh | sh
```

Pin to a specific version:

```bash
curl -LsSf https://github.com/TheSmuks/pmp/install.sh | env PMP_VERSION=v0.5.0 sh
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PMP_INSTALL_DIR` | `~/.pmp` | Installation directory |
| `PMP_VERSION` | latest | Pin to a specific git tag |
| `PMP_MODIFY_PATH` | unset | Set to `1` to enable shell rc PATH modification |

Re-running the installer updates pmp in place (git pull).

## Upgrading

```bash
pmp self-update
```

Or re-run the installer:

```bash
curl -LsSf https://github.com/TheSmuks/pmp/install.sh | sh
```

## Uninstall

```bash
rm -rf ~/.pmp
rm -rf ~/.pike/store
```

Remove the PATH line from your shell rc (`~/.bashrc`, `~/.zshrc`, or `~/.profile`):

```
export PATH="$HOME/.pmp/bin:$PATH"
```

## Invoking pmp

Use `sh bin/pmp` (or `$PATH/pmp` after installation). The shell shim sets `PIKE_MODULE_PATH` to the `bin/` directory so Pike can resolve `import Pmp.Config` etc.

Direct invocation (`pike bin/pmp.pike`) does **not** work — Pike resolves `import Pmp.Config` before the shim runs, and `PIKE_MODULE_PATH` is not set. The shell shim (`bin/pmp`) sets this correctly before delegating to Pike.

## Quick start

```bash
# Initialize a project
pmp init

# Install from GitHub
pmp install github.com/thesmuks/punit-tests#v1.0.0

# Create an isolated environment
pmp env
. .pike-env/activate

# Run your code with module paths set
pmp run my_script.pike
```

## Source types

pmp auto-detects the source type from the URL format:

| URL format | Type | Version resolution |
|---|---|---|
| `github.com/owner/repo` | GitHub | GitHub tags API |
| `gitlab.com/owner/repo` | GitLab | GitLab tags API |
| `git.example.com/owner/repo` | Self-hosted git | `git ls-remote --tags` |
| `./relative/path` or `/abs/path` | Local | None (dev mode, symlinked) |

Append `#tag` to pin a version. Without it, pmp resolves the latest tag.

## Content-addressable store

pmp uses a global content-addressable store at `~/.pike/store/`. Each package version is downloaded once and shared across projects via symlinks:

```
~/.pike/store/
  github.com-thesmuks-punit-v1.0.0-a1b2c3d4e5f67890/   # immutable store entry
    PUnit.pmod/
    pike.json
    .pmp-meta                                     # source, tag, commit SHA, content hash

your-project/
  modules/
    PUnit/    → symlink to ~/.pike/store/github.com-thesmuks-punit-v1.0.0-a1b2c3d4e5f67890/
```

**Benefits:**
- Instant installs when a package is already in the store
- Zero disk duplication across projects
- Store survives `pmp clean` — only project symlinks are removed

Store entry names include the first 16 characters of the commit SHA to disambiguate force-pushed tags.

## pike.lock (lockfile)

After every install, pmp writes `pike.lock` with exact commit SHAs and content hashes:

```
# pmp lockfile v1 — DO NOT EDIT
# name	source	tag	commit_sha	content_sha256
PUnit	github.com/thesmuks/punit-tests	v1.0.0	a1b2c3d4e5f6...	abcdef1234...
LocalLib	./libs/my-lib	-	-	-
```

**Commit `pike.lock` to git** for reproducible builds. When it exists, `pmp install` uses the lockfile to skip resolution and install exact versions.

- `pike.json` = what you want (declarative, may have `#tag` or omit it)
- `pike.lock` = what you got (exact commit SHA, always pinned)

- `pike.lock.prev` = previous lockfile (automatic backup created on every install/update, used by `pmp rollback`)

## Integrity verification

Every remote package download is verified with SHA-256. The hash is recorded in both `.pmp-meta` (in the store) and `pike.lock`. On lockfile-based reinstalls, the hash is compared to ensure the content hasn't changed.

## Transitive dependencies

Packages can declare their own dependencies in their `pike.json`:

```json
{
  "name": "MyLib",
  "version": "1.0.0",
  "dependencies": {
    "PUnit": "github.com/thesmuks/punit-tests#v1.0.0"
  }
}
```

pmp resolves transitive dependencies recursively. The lockfile captures the full resolved tree. Cycle detection prevents infinite loops.

**Conflict resolution:** if two packages need different versions of the same dependency, the first-installed version wins and a warning is emitted.

## Manifest validation

After installing, pmp scans each package's `.pike`/`.pmod` files for `import` statements and warns about imports that reference modules not declared in the package's `pike.json`. This encourages explicit dependency declarations.

Validation is warn-only — it will not block installs.
## pike.json

Project manifest in your project root:

```json
{
  "dependencies": {
    "PUnit": "github.com/thesmuks/punit-tests#v1.0.0",
    "OtherMod": "gitlab.com/someuser/other-mod",
    "LocalLib": "./libs/my-lib"
  }
}
```

- **Key**: module name (directory name in `./modules/`)
- **Value**: source URL or local path
- `#version` suffix is optional — defaults to latest tag
- Local paths are symlinked, not copied — changes are immediately visible

### Package manifest

In the package repository itself:

```json
{
  "name": "PUnit",
  "version": "1.0.0",
  "description": "JUnit-inspired testing framework for Pike",
  "source": "github.com/thesmuks/punit-tests",
  "dependencies": {
    "SomeDep": "github.com/owner/dep#v2.0.0"
  }
}
```

The `dependencies` block enables transitive resolution when other projects install this package.

## pmp env (virtual environment)

Creates `.pike-env/` with a scoped Pike wrapper:

```bash
pmp env          # creates .pike-env/
. .pike-env/activate   # activate
pike my_script.pike    # uses project module paths
pmp_deactivate         # restore system Pike
```

The wrapper:
- Injects `PIKE_MODULE_PATH` and `PIKE_INCLUDE_PATH` for the project
- Resolves local dependencies from `pike.json` on every invocation
- Falls back to global modules in `~/.pike/modules/`

## Commands

```
pmp init                                    Create pike.json scaffold
pmp install                                 Install all deps (from lockfile or pike.json)
pmp install <url>                           Add + install (latest tag)
pmp install <url>#tag                       Install specific version
pmp install ./local/path                    Local dependency (symlinked)
pmp install -g <url>                        Install system-wide
pmp install --frozen-lockfile               CI: fail if lockfile is missing or stale
pmp install --offline                       Install from store only (no network)
pmp add <url>                               Alias for pmp install <url>
pmp update                                  Update all to latest tags
pmp update <module>                         Update one dependency
pmp rollback                                Rollback to previous lockfile
pmp changelog <module>                      Show commit log between versions
pmp lock                                    Resolve and write pike.lock without installing
pmp store                                   Show store entries and disk usage
pmp store prune [--force]                   Remove unused store entries
pmp list [-g]                               Show installed modules
pmp env                                     Create .pike-env/
pmp clean                                   Remove ./modules/ (keeps store)
pmp remove <name>                           Remove a dependency
pmp run <script>                            Run script with module paths
pmp outdated                                Show deps with newer versions available
pmp resolve [module]                        Print resolved module paths
pmp version                                 Show pmp version
pmp self-update                             Update pmp to the latest version
pmp verify                                  Verify installed dependencies
pmp doctor                                  Diagnose common project issues
pmp pmpx <source> [-- args...]              Execute module without installing
```

> **Note:** pmp uses [Semantic Versioning](https://semver.org/) for tag comparison. Only tags matching MAJOR.MINOR.PATCH (with optional `v` prefix and `-prerelease` suffix) are sorted correctly. Non-semver tags are deprioritized.

## pmpx (one-shot execution)

Download and execute a remote Pike module without installing it into your project. No `pike.json`, `modules/`, or `pike.lock` files are modified.

```bash
# Run the latest version of a module
pmp pmpx github.com/owner/repo

# Pin to a specific version
pmp pmpx github.com/owner/repo#v1.0.0

# Pass arguments to the executed module
pmp pmpx github.com/owner/repo -- --verbose --output=json
```

**Entry point resolution** (in order):

1. `pike.json` `"bin"` field (e.g. `{"bin": "cli.pike"}`)
2. Heuristic filenames: `main.pike`, `cli.pike`, `cmd.pike`
3. Single `.pike` file at the package root (unambiguous)

The module is downloaded to the shared content-addressable store (`~/.pike/store/`) and reused on subsequent runs. Local paths are not supported — use `pmp install ./path` instead.

## Selective .h imports

PUnit-style packages use granular header files. Import only what you need:

```c
#include <PUnit.pmod/assert_equal.h>
#include <PUnit.pmod/assert_true.h>
```

Or include all assertions:

```c
#include <PUnit.pmod/macros.h>
```

## LSP integration

For language server support, configure your LSP to use the pike wrapper from `.pike-env/bin/pike`. This ensures module resolution matches runtime behavior.

## Requirements

- Pike 8.0+ (provides HTTP client, JSON parser, SHA-256, tar extraction natively)
- `gunzip` (for .tar.gz decompression)
- `git` (for self-hosted sources only; not needed for GitHub/GitLab)

## License

MIT

# pmp — Pike Module Package Manager

[![CI](https://github.com/TheSmuks/pmp/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSmuks/pmp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Install, version, and resolve dependencies for Pike modules. Works with GitHub, GitLab, self-hosted git, and local paths.

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
  github.com-thesmuks-punit-v1.0.0-a1b2c3d4/   # immutable store entry
    PUnit.pmod/
    pike.json
    .pmp-meta                                     # source, tag, commit SHA, content hash

your-project/
  modules/
    PUnit/    → symlink to ~/.pike/store/github.com-thesmuks-punit-v1.0.0-a1b2c3d4/
```

**Benefits:**
- Instant installs when a package is already in the store
- Zero disk duplication across projects
- Store survives `pmp clean` — only project symlinks are removed

Store entry names include the first 8 characters of the commit SHA to disambiguate force-pushed tags.

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

Validation is warn-only in v0.2.0 — it will not block installs.

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
pmp update                                  Update all to latest tags
pmp update <module>                         Update one dependency
pmp lock                                    Resolve and write pike.lock without installing
pmp store                                   Show store entries and disk usage
pmp store prune                             Show unused store entries
pmp list                                    Show installed modules
pmp clean                                   Remove ./modules/ (keeps store)
pmp env                                     Create .pike-env/
pmp run <script>                            Run script with module paths
pmp version                                 Show pmp version
```

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

- POSIX sh (dash, bash, etc.)
- Pike 8.0+
- `curl` (for GitHub/GitLab downloads)
- `tar` (for archive extraction)
- `git` (for self-hosted sources)
- `sha256sum` or `shasum` (for integrity verification; optional — falls back to "unknown")

## License

MIT

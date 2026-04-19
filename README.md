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
  "source": "github.com/thesmuks/punit-tests"
}
```

This is informational — it tells consumers where the package lives.

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
pmp install                                 Install all from pike.json
pmp install <url>                           Add + install (latest tag)
pmp install <url>#tag                       Install specific version
pmp install ./local/path                    Local dependency (symlinked)
pmp install -g <url>                        Install system-wide
pmp update                                  Update all to latest tags
pmp update <module>                         Update one dependency
pmp list                                    Show installed modules
pmp clean                                   Remove ./modules/
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

- Pike 8.0+
- `curl` (for GitHub/GitLab downloads)
- `tar` (for archive extraction)
- `git` (for self-hosted sources)

## License

MIT

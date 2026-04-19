# pmp — Pike Module Package Manager

A minimal package manager for Pike modules. Install, version, and resolve dependencies so that `import Module;` just works.

## Quick start

```bash
# One-time setup: install the pike wrapper
pmp init

# Install a dependency
pmp install PUnit

# Now any Pike script in this directory can: import PUnit;
pike my_test.pike
```

No `-M` flags. No manual path configuration. The `pike` wrapper auto-detects `pike.json` and injects module paths.

## How it works

### Three layers of resolution

```
1. ./modules/              per-project (pmp install)
2. ~/.pike/modules/        system-wide  (pmp install -g)
3. Pike stdlib             built-in
```

### The `pike` wrapper

`pmp init` installs a `pike` shell script to `~/.local/bin/` (must be in PATH). When invoked:

1. Walks up from `$PWD` to find `pike.json`
2. If found and `./modules/` exists, injects it into `PIKE_MODULE_PATH`
3. Also injects `~/.pike/modules/` (global modules)
4. `exec`s the real Pike binary

Pike's `master.pike` reads `PIKE_MODULE_PATH` and adds each entry to its internal module search path. `import X` resolves to `X.pmod/` in one of those directories.

### The `pike` wrapper also handles `.h` files

If installed modules contain `.h` files (like PUnit's granular assertion headers), their directories are added to `PIKE_INCLUDE_PATH`. This makes `#include <PUnit.pmod/equal.h>` resolve without manual configuration.

## Manifest: `pike.json`

```json
{
  "dependencies": {
    "PUnit": {
      "source": "github:TheSmuks/punit",
      "version": "v1.0.0"
    }
  }
}
```

- `source`: `github:owner/repo` (v1 supports GitHub only)
- `version`: exact git tag, or omit for `latest`

## Commands

```
pmp init                  Install pike wrapper to ~/.local/bin/
pmp install               Install all deps from pike.json into ./modules/
pmp install <module>      Add module (latest tag) and install
pmp install <module>@tag  Install specific version
pmp install -g <module>   Install system-wide to ~/.pike/modules/
pmp update [module]       Update to latest tags
pmp list [-g]             Show installed dependencies and versions
pmp clean                 Remove ./modules/
pmp run <script.pike>     Run script with module paths injected
pmp version               Show pmp version
```

## Selective import via `.h` headers

Pike's `import Module;` dumps every symbol into scope — there's no `from X import Y`. Module authors can provide granular `.h` files as an alternative:

```pike
// Instead of: import PUnit;  (all 20 assertions)
// Use:        #include <PUnit.pmod/equal.h>  (only assert_equal + assert_not_equal)

#include <PUnit.pmod/equal.h>

int main() {
  assert_equal(2, 1+1);  // works
  // assert_true(1);      // compile error — not in scope
}
```

The `.h` files contain `#define` macros that expand to qualified calls (`PUnit.assert_equal(...)`) with automatic `__FILE__:__LINE__` injection. Zero runtime cost.

**Convention for module authors**: provide both a `macros.h` (all macros) and granular sub-headers:

```
YourModule.pmod/
  macros.h        ← all macros (includes the granular headers)
  equal.h         ← specific subset
  boolean.h       ← specific subset
  ...
```

## LSP integration

The pike wrapper sets `PIKE_MODULE_PATH` before invoking Pike. The Pike LSP spawns a Pike subprocess that inherits this environment variable. No LSP configuration changes needed — `import PUnit` resolves automatically in the LSP.

For LSP setups that configure include paths explicitly, add `./modules` to `includePaths` when `pike.json` is present.

## Requirements

- POSIX shell (sh)
- [Pike](https://pike.lysator.liu.se/) 8.0+
- `curl`, `tar` for downloads

## License

MIT

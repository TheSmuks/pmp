# Changelog

All notable changes to pmp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
feat(repo): upgraded ai-project-template from v0.2.0 to v0.6.0 — adds branch-cleanup.yml
  CI workflow, OMP skills (merge-to-main, cut-release, template-guide, setup), OMP rules
  (no-placeholders, changelog-required, conventional-commits), pre/post hooks (protect-main,
  template-compliance-hint), template-audit tool, and agent/docs guides
feat(repo): pmp practices what it preaches — pike.json now has proper name ("pmp"), version ("0.5.0"), and description; pike.lock is committed to git (removed from .gitignore) for CI reproducibility; CI now uses --frozen-lockfile; OMP rules added to enforce these invariants going forward
feat(cli): `pmp outdated --json` — machine-readable JSON output for tooling and CI integration; exits 1 if any dependencies are outdated, 0 if all up to date
feat(ci): reusable GitHub Actions workflow `.github/workflows/dep-update.yml` — any Pike project can opt-in to automatic dependency update PRs via `uses: TheSmuks/pmp/.github/workflows/dep-update.yml@main`

### Changed
docs(readme): restructured README to Bun-style layout — key info up top, quick-links index, detailed sections below fold

### Fixed
fix(ci): dep-update.yml install step uses `curl -LsSf <url> | sh` instead of `sh <url>` — `sh` cannot fetch URLs, causing `pmp: command not found` in downstream steps
fix(install): lockfile replay path (`pmp install --frozen-lockfile`) now resolves the package's
  actual module name from pike.json before creating symlinks — previously it used the
  dependency key name directly, causing `import PUnit` to fail when the package's pike.json
  declared name "PUnit" but the lockfile key was "punit-tests"
fix(install): `pmp install` now resolves modules in Cargo-style `src/` layout — packages with `src/PackageName.pmod/module.pmod` are correctly detected and symlinked. Also supports `"module_path"` field in pike.json for explicit declaration (equivalent to Cargo's `[lib] path`). Fixes broken imports for packages like pike-introspect that use non-root layout. Backward compatible with existing flat and nested layouts.


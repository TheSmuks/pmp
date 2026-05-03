# Changelog

All notable changes to pmp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
feat(cli): `pmp outdated --json` — machine-readable JSON output for tooling and CI integration; exits 1 if any dependencies are outdated, 0 if all up to date
feat(ci): reusable GitHub Actions workflow `.github/workflows/dep-update.yml` — any Pike project can opt-in to automatic dependency update PRs via `uses: TheSmuks/pmp/.github/workflows/dep-update.yml@main`

### Changed
docs(readme): restructured README to Bun-style layout — key info up top, quick-links index, detailed sections below fold

### Fixed
fix(ci): dep-update.yml install step uses `curl -LsSf <url> | sh` instead of `sh <url>` — `sh` cannot fetch URLs, causing `pmp: command not found` in downstream steps

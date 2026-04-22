# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in pmp, please report it responsibly:

- **Email**: Open a GitHub Security Advisory at
  https://github.com/TheSmuks/pmp/security/advisories/new
- **Do not** file a public issue for security vulnerabilities.

## What to include

- Description of the vulnerability
- Steps to reproduce
- Affected versions (check `pmp version`)
- Potential impact

## Response timeline

- **Acknowledgment**: within 48 hours
- **Initial assessment**: within 5 business days
- **Fix or mitigation**: depends on severity

  | Severity | Target |
  |----------|--------|
  | Critical (RCE, data loss) | 24-48 hours |
  | High (privilege escalation) | 3-5 business days |
  | Medium (info leak, DoS) | Next release |
  | Low (minor info exposure) | Next release |

## Supported versions

Only the latest release is supported with security fixes.

## Known security considerations

- **Tarball extraction**: pmp extracts downloaded archives using system `tar`
  with `--no-same-owner` and validates against symlink path traversal. Crafted
  archives may still pose risks if the extraction logic has gaps.
- **Lockfile integrity**: pmp verifies content hashes from the lockfile against
  stored entries. Tampered store entries are detected on install.
- **HTTP transport**: All remote fetches use HTTPS. No integrity verification
  is performed on the installer script (`install.sh`); users should verify
  the script before running it.
- **Store directory**: The content-addressable store (`~/.pike/store/`) is
  protected by a PID-based advisory lock. Concurrent pmp processes are
  detected and blocked.

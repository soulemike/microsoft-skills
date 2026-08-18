# Security Policy

## Supported Versions

We release security patches for the latest version on the main branch.

## Reporting a Vulnerability

Please report security vulnerabilities by opening a private security advisory on GitHub:
https://github.com/microsoft/cloud-api-skills/security/advisories/new

We aim to respond within 5 business days and will coordinate disclosure timelines with you.

## Security Design

This project follows these security principles:

- **No embedded secrets** — Secrets are never hardcoded in scripts.
- **Auth hierarchy enforcement** — Managed Identity > Federated > Certificate > Client Secret (with runtime warning).
- **Context isolation** — Auth contexts are explicit hashtables; no global session state.
- **Multi-tenant safety** — Prefixed environment variables and profile-based configs prevent accidental cross-tenant operations.

See [`docs/secret-management.md`](docs/secret-management.md) for detailed secret handling rules.

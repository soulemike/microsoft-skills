# Multi-Tenant Authentication

> **Purpose:** Expand the multi-tenant and multi-context guidance in `agents.md` into concrete configuration and session-management patterns.

---

## 1. Why This Matters

The toolkit is expected to support automation that touches more than one Entra tenant or more than one environment at a time, for example:

- dev / test / prod separation
- commercial + gov operations in one codebase
- partner or migration scenarios spanning multiple tenants

The main risk is accidental context bleed: obtaining a token in one tenant or cloud and reusing it against another.

---

## 2. Supported Pattern A: Centralized Configuration File

The preferred pattern for multi-context automation is a single config file with named profiles.

### Example YAML

```yaml
environments:
  prod:
    tenantId: "00000000-0000-0000-0000-000000000001"
    azureEnvironment: "AzureCloud"
    authenticationType: "ManagedIdentity"
  gov:
    tenantId: "00000000-0000-0000-0000-000000000002"
    azureEnvironment: "AzureUSGovernment"
    authenticationType: "Certificate"
    certificatePath: "/secure/certs/gov-automation.pfx"
  partner:
    tenantId: "00000000-0000-0000-0000-000000000003"
    azureEnvironment: "AzureCloud"
    authenticationType: "Federated"
    clientId: "00000000-0000-0000-0000-000000000004"
```

### Target behavior

- `Connect-*` functions should accept `-Profile` and/or `-ConfigPath`
- the named profile should supply default tenant, cloud, and auth settings
- explicit parameters should override profile values when intentionally supplied

### Why this pattern is preferred

It keeps non-secret configuration audit-friendly, versionable, and visible in one place.

---

## 3. Supported Pattern B: Prefixed Environment Variables

When configuration files are not practical, the toolkit supports tenant-scoped prefixes.

### Example

```bash
# Default / backward-compatible
TENANT_ID=...
CLIENT_ID=...

# Tenant-scoped
PROD_TENANT_ID=...
PROD_CLIENT_ID=...
PROD_USE_MANAGED_IDENTITY=true

GOV_TENANT_ID=...
GOV_CLIENT_ID=...
GOV_CERTIFICATE_PATH=/secure/certs/gov.pfx
```

### Target behavior

- `-Prefix 'GOV'` should map `GOV_TENANT_ID` to `TenantId`
- omitting `-Prefix` should fall back to the unprefixed values for backward compatibility
- prefixes should be stable and environment-oriented, for example `PROD`, `GOV`, `PARTNER`

This matches the multi-context examples already present in `.env.example`.

> **Implementation note:** This document captures the multi-tenant contract defined in `agents.md`. Some current service scripts may not yet expose every profile- or prefix-based parameter directly; use this guidance as the standard for new and updated `Connect-*` functions.

---

## 4. Session Isolation Rules

The safest design is to return a context object from each connection call and pass it explicitly to request wrappers.

### Recommended pattern

```powershell
$prodContext = Connect-GraphApi -Profile 'prod' -ConfigPath './config.yaml'
$govContext  = Connect-GraphApi -Prefix 'GOV'

Invoke-GraphRequest -Context $prodContext -Uri '/users'
Invoke-GraphRequest -Context $govContext  -Uri '/users'
```

Each context should carry at least:

- token
- expiry
- audience
- tenant
- cloud / environment

### Acceptable fallback

Module-scoped variables are acceptable only for single-context usage. Once a second context is active, state should be overwritten deliberately or stored in a dictionary keyed by tenant or profile.

---

## 5. Recommended Precedence Model

When multiple config sources exist, use this precedence:

1. **Explicit function parameters**
2. **Resolved profile values** from `-Profile` / `-ConfigPath`
3. **Prefixed environment variables** from `-Prefix`
4. **Unprefixed environment variables** for backward compatibility

This keeps overrides intentional and predictable.

---

## 6. Naming Guidance

Use human-meaningful profile or prefix names instead of raw tenant IDs.

Good examples:

- `prod`
- `gov`
- `partner`
- `dev`

Less helpful examples:

- `tenant1`
- `misc`
- `x`

The goal is operational clarity when multiple tokens and environments exist in the same run.

---

## 7. Practical Rules

- Prefer config files for non-secret multi-tenant configuration.
- Use prefixes when config files are unavailable.
- Keep one explicit context object per active tenant or cloud.
- Never assume a module-global token still points at the tenant you think it does.

Related docs:

- `docs/auth-patterns.md`
- `docs/secret-management.md`
- `docs/token-chaining.md`

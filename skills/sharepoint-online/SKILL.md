# SharePoint Online Skill

## Overview

SharePoint Online is currently a **documented gap** in this toolkit. The service requires different tooling for data plane versus management plane operations, and Microsoft Graph provides only partial coverage.

## Why This Is a Gap

SharePoint Online is not a single API surface. Data plane operations (lists, libraries, files, pages) and management plane operations (tenant settings, site provisioning, governance) require different tools and token audiences.

## Tooling Landscape

| Plane | Tool | Best For | Auth | Limitations |
|-------|------|----------|------|-------------|
| **Data** | **PnP PowerShell** | Broadest coverage for site content, lists, libraries, files, pages | Certificate (modern app-only), managed identity, interactive | Community-driven (no Microsoft SLA); client secrets not supported for modern app-only |
| **Data** | **Microsoft Graph** | Standardized REST across M365; strong typing | App-only or delegated; `Sites.Read.All` / `Sites.FullControl.All` | **Partial coverage**: read-only site resources; no site creation via Graph |
| **Data** | **SharePoint REST API** | Native SharePoint HTTP endpoints; features missing from Graph | SharePoint audience token | Requires `X-RequestDigest` for writes |
| **Data** | **CSOM** | Deep .NET SharePoint-specific behavior | SharePoint audience token | Verbose; .NET Standard lacks legacy auth |
| **Management** | **SharePoint Online Management Shell** | Tenant-level admin operations | `SharePoint Administrator` role; certificate or managed identity | Classic admin tool; limited to supported operations |
| **Management** | **PnP PowerShell tenant cmdlets** | Site provisioning, governance, tenant settings | Same as data plane PnP | Same limitations as data plane PnP |
| **Management** | **Microsoft Graph** | Limited tenant settings automation | `SharePointTenantSettings.ReadWrite.All` | Very limited surface; not full parity with SPO Management Shell |

## Authentication Requirements

- **Modern unattended automation**: Certificate-based auth or managed identity. Client secrets are **not supported** by PnP PowerShell for modern Entra app-only.
- **PnP PowerShell**: `Connect-PnPOnline -CertificatePath ... -Tenant ... -ClientId ...` or `-ManagedIdentity`
- **Graph**: Standard Entra app-only with `Sites.Read.All` or `Sites.FullControl.All`; consider `Sites.Selected` for least privilege
- **SharePoint REST / CSOM**: Requires a SharePoint audience token, not a Graph token
- **ACS / SharePoint Add-in auth**: **Retired April 2, 2026**. Do not use for new automation.

## When This Gap Will Be Addressed

SharePoint Online skills are planned for a future iteration. The recommended approach is:
1. Data plane: PnP PowerShell with certificate-based auth
2. Management plane: PnP PowerShell tenant cmdlets or SPO Management Shell
3. Graph: Use only for read-only site metadata where PnP is unnecessary

## Related Docs
- [Patterns and Caveats](../docs/patterns-and-caveats.md)
- [Auth Patterns](../docs/auth-patterns.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

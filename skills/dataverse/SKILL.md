---
name: dataverse
description: Use this skill for Microsoft Dataverse Web API automation with OData queries, environment-aware authentication, and pagination-aware REST calls.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - dataverse
  - dynamics-365
  - odata
  - powershell
  - automation
metadata:
  project: microsoft-cloud-api-skills
  domain: dataverse
---

# Dataverse Skill

## Agent Summary
Use this skill for Dataverse Web API requests when an agent needs direct OData access instead of PAC CLI abstractions. The token audience is the Dataverse environment URL itself, so start by creating a context with `Connect-DataverseApi.ps1`.

## When to Use
- Query Dataverse tables with OData filters, selects, and pagination.
- Connect to a known Dataverse environment or discover one through the Global Discovery Service.
- Perform direct CRUD operations against Dataverse entities.

## Required Parameters
### `Connect-DataverseApi.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `EnvironmentUrl` | `string` | Yes | Dataverse environment root URL or full Web API URL. |
| `AuthenticationType` | `string` | Conditional | `ManagedIdentity`, `Federated`, `Certificate`, or `ClientCredentials`. |
| `Environment` | `string` | No | Defaults to `AzureCloud`. |
| `TenantId` | `string` | Conditional | Required for `Federated`, `Certificate`, and `ClientCredentials`. |
| `ClientId` | `string` | Conditional | Required for `Federated`, `Certificate`, and `ClientCredentials`. |
| `FederatedToken` | `string` | Conditional | Required for `Federated`. |
| `CertificatePath` | `string` | Conditional | Required for `Certificate`. |
| `ClientSecret` | `SecureString` | Conditional | Required for `ClientCredentials`. |

### `Invoke-DataverseRequest.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Uri` | `string` | Yes | Relative Dataverse API path or absolute nextLink URL. |
| `AuthContext` | `hashtable` | Yes | Output from `Connect-DataverseApi.ps1`. |
| `Method` | `string` | No | Defaults to `GET`. |
| `Body` | `object` | No | Request payload for writes. |
| `Paginate` | `switch` | No | Aggregates `@odata.nextLink` pages. |

## Example Agent Prompts
- "List the first 50 Dataverse accounts with `accountid` and `name`."
- "Query Dataverse contacts where `emailaddress1` is not null."
- "Patch a Dataverse account record by ID."

## Example Agent Workflow
```powershell
$ctx = ./skills/dataverse/Connect-DataverseApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud -EnvironmentUrl $env:DATAVERSE_ENVIRONMENT_URL

$accounts = ./skills/dataverse/Invoke-DataverseRequest.ps1 -AuthContext $ctx -Uri "/accounts?`$select=accountid,name&`$top=50" -Paginate
```

## Security Caveats
- The Dataverse environment URL is the token audience; do not substitute Graph or ARM tokens.
- Prefer managed identity or federated credentials over client secrets.
- Grant only the Dataverse roles and table permissions required for the requested entity operations.

## Overview
This skillset connects to Microsoft Dataverse Web API and executes OData requests with consistent auth, environment discovery, and retry behavior.

## Authentication
- Auth types: ManagedIdentity, Federated, Certificate, ClientCredentials (emits a mandatory warning when using client secrets).
- Token audience is the environment URL itself (not Graph or ARM). The environment root URL is used as the OAuth resource, so the token is scoped with `$Resource/.default`.
- Global Discovery Service for environment lookup to translate an environment URL into the correct Web API base URI.

## Endpoints
| Environment | GDS Endpoint | Environment URL Pattern |
|-------------|--------------|------------------------|
| AzureCloud | https://globaldisco.crm.dynamics.com | https://*.crm.dynamics.com |
| AzureUSGovernment | https://globaldisco.crm9.dynamics.com | https://*.crm9.dynamics.com |
| AzureChinaCloud | https://globaldisco.crm.dynamics.cn | https://*.crm.dynamics.cn |

## Skills
| File | Purpose |
|------|---------|
| Connect-DataverseApi.ps1 | Establishes the Dataverse Web API connection context, resolves the Web API base URI (via GDS when `-Environment` is provided), and acquires the bearer token.
| Invoke-DataverseRequest.ps1 | Sends Dataverse Web API requests with Dataverse-specific OData headers, supports `@odata.nextLink` pagination via `-Paginate`, and handles relative versus absolute URIs.
| Get-DataverseEnvironment.ps1 | Queries the Global Discovery Service (GDS) for available Dataverse environments for the selected cloud.
| auth/*.ps1 | Thin wrappers that fix `AuthenticationType` to ManagedIdentity, Federated, Certificate, or ClientCredentials.

## Toolchain
| Tool | Best For | Token Audience | Limitations in Dataverse Context |
|------|----------|----------------|---------------------------------|
| **PAC CLI** (`pac`) | Solution packaging, environment management, agent deployment | Power Platform admin scope; internally handles Dataverse token acquisition | Does not expose all Dataverse entity fields; limited to supported operations; cannot perform arbitrary OData queries |
| **Raw REST (`Invoke-RestMethod`)** | Full OData query flexibility, custom entity operations, file uploads/downloads | Dataverse environment URL (e.g., `https://*.crm.dynamics.com`) | Caller must handle pagination, throttling, retry logic, and token refresh manually |

## Patterns & Caveats
- OData query syntax
- File uploads/downloads need special handling
- Pagination
- Environment URL as token audience

## Examples
```powershell
# 1) GDS lookup, then run an OData query with pagination
$authToken = $env:AZURE_FEDERATED_TOKEN

$environments = Get-DataverseEnvironment.ps1 \
  -AuthenticationType Federated \
  -TenantId $env:TENANT_ID \
  -ClientId $env:CLIENT_ID \
  -FederatedToken $authToken \
  -Environment AzureCloud

$target = $environments | Where-Object { $_.UniqueName -eq 'contoso' } | Select-Object -First 1

$ctx = Connect-DataverseApi.ps1 \
  -AuthenticationType Federated \
  -TenantId $env:TENANT_ID \
  -ClientId $env:CLIENT_ID \
  -FederatedToken $authToken \
  -Environment AzureCloud \
  -EnvironmentUrl $target.url

$accounts = Invoke-DataverseRequest.ps1 \
  -AuthContext $ctx \
  -Uri "/accounts?`$select=accountid,name&`$top=5000" \
  -Paginate
```

```powershell
# 2) Certificate-based auth and a filtered OData query
$ctx = Connect-DataverseApi.ps1 \
  -AuthenticationType Certificate \
  -TenantId $env:TENANT_ID \
  -ClientId $env:CLIENT_ID \
  -CertificatePath "/secure/certs/app.pfx" \
  -Environment AzureCloud \
  -EnvironmentUrl $env:DATAVERSE_ENVIRONMENT_URL

$contacts = Invoke-DataverseRequest.ps1 \
  -AuthContext $ctx \
  -Uri "/contacts?`$select=contactid,fullname,emailaddress1&`$filter=emailaddress1 ne null" \
  -Paginate
```

```powershell
# 3) Patch a record using the Dataverse Web API
$ctx = Connect-DataverseApi.ps1 \
  -AuthenticationType ManagedIdentity \
  -Environment AzureCloud \
  -EnvironmentUrl $env:DATAVERSE_ENVIRONMENT_URL

$accountId = "00000000-0000-0000-0000-000000000001"

Invoke-DataverseRequest.ps1 \
  -AuthContext $ctx \
  -Method PATCH \
  -Uri "/accounts($accountId)" \
  -Body @{ name = 'Contoso Updated Account' }
```

## Prerequisites
- Required modules: PowerShell 7.2+; Az.Accounts, Az.Resources, and Azure modules installed via `prerequisites/Install-RequiredModules.ps1` (MSAL.PS optional for certificate validation).
- Required permissions: An Entra ID app registration with Dataverse Web API access for the specific Dataverse environment (the token audience is the environment URL), plus Dataverse security roles that permit the entity reads and writes you will perform.

## Related Docs
- [Auth Patterns](../../docs/auth-patterns.md)
- [Token Chaining](../../docs/token-chaining.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)

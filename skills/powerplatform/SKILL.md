---
name: powerplatform
description: Use this skill for Power Platform Business Applications Platform admin API automation with ARM-scoped authentication and paginated environment enumeration.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - power-platform
  - bap
  - admin
  - powershell
  - automation
metadata:
  project: microsoft-cloud-api-skills
  domain: powerplatform
---

# Power Platform / BAP Skill

## Agent Summary
Use this skill for Power Platform admin environment discovery through the Business Applications Platform (BAP) API. Even though this is a Power Platform domain, the API expects an ARM-scoped token rather than a Dataverse token.

## When to Use
- List Power Platform admin environments.
- Expand environment properties such as capacity or addons.
- Reuse Azure auth patterns against the BAP endpoint.

## Required Parameters
### `Connect-PowerPlatformApi.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `AuthenticationType` | `string` | Conditional | `ManagedIdentity`, `Federated`, `Certificate`, or `ClientCredentials`. |
| `Environment` | `string` | No | Defaults to `AzureCloud`. |
| `TenantId` | `string` | Conditional | Required for `Federated`, `Certificate`, and `ClientCredentials`. |
| `ClientId` | `string` | Conditional | Required for `Federated`, `Certificate`, and `ClientCredentials`; optional for user-assigned managed identity. |
| `FederatedToken` | `string` | Conditional | Required for `Federated`. |
| `CertificatePath` | `string` | Conditional | Required for `Certificate`. |
| `ClientSecret` | `SecureString` | Conditional | Required for `ClientCredentials`. |

### `Get-PowerPlatformEnvironment.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Context` | `object` | Yes | Output from `Connect-PowerPlatformApi.ps1`. |
| `ApiVersion` | `string` | No | Defaults to `2020-10-01`. |
| `Expand` | `string` | No | Optional property expansion string. |

## Example Agent Prompts
- "List all Power Platform admin environments."
- "Show Power Platform environments with capacity and addon details."
- "Call the BAP admin environments endpoint in Azure US Government."

## Example Agent Workflow
```powershell
$ctx = ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

$envs = ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $ctx
```

## Security Caveats
- Use an ARM-scoped token, not a Dataverse token.
- Prefer managed identity or federated credentials over client secrets.
- Restrict access to Power Platform admin environment listing to the smallest admin scope that satisfies the task.

## Overview
This skill connects to the Power Platform Business Applications Platform (BAP) API and uses an ARM-scoped bearer token to enumerate admin environments.

## Authentication
- ARM-scoped token (BAP is an Azure Resource Provider)
- Same auth hierarchy as ARM: ManagedIdentity > Federated > Certificate > ClientSecret

## Endpoints
| Environment | BAP API Endpoint |
|-------------|------------------|
| AzureCloud | https://api.bap.microsoft.com |
| AzureUSGovernment | https://api.bap.microsoft.us |
| AzureChinaCloud | https://api.bap.microsoft.cn |

## Skills
| File | Purpose |
|------|---------|
| Connect-PowerPlatformApi.ps1 | Resolves the BAP base URI for the selected Azure cloud, acquires an ARM-scoped access token using the shared auth helpers, and returns a connection context for downstream calls. |
| Get-PowerPlatformEnvironment.ps1 | Calls the BAP admin environments endpoint, follows nextLink or @odata.nextLink until all pages are retrieved, and returns the collected environment records. |

## Patterns & Caveats
- BAP API uses ARM tokens, not Dataverse tokens
- Admin environments endpoint: /providers/Microsoft.BusinessAppPlatform/scopes/admin/environments
- Pagination via nextLink and @odata.nextLink
- api-version: 2020-10-01

## Examples
1) List environments using managed identity

```powershell
$ctx = ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
$envs = ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $ctx
$envs | Select-Object -First 5
```

2) List environments with expanded properties in US Gov

```powershell
$ctx = ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -AuthenticationType Federated -Environment AzureUSGovernment -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -FederatedToken $env:AZURE_FEDERATED_TOKEN
$envs = ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $ctx -Expand 'properties.capacity,properties.addons'
$envs | Format-Table -AutoSize
```

3) Use a named profile and retrieve only the admin environments list

```powershell
$ctx = ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -Profile prod -Environment AzureCloud
$envs = ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $ctx -ApiVersion '2020-10-01'
$envs | Where-Object { $_.name } | Select-Object name, state -First 10
```

## Prerequisites
- Required modules: Az.Accounts, Az.Resources, optional MSAL.PS (used for certificate token acquisition)
- Required roles: permissions to call the BAP admin environments endpoint (/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments)

## Related Docs
- [Auth Patterns](../../docs/auth-patterns.md)
- [Token Chaining](../../docs/token-chaining.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)

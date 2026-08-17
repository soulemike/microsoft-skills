# Microsoft Graph Skill

## Overview
This skill domain covers unattended Microsoft Graph API automation using app-only authentication. It provides a standardized way to acquire Graph tokens for different Azure environments and invoke Graph REST requests with pagination and throttling-aware retries.

## Authentication
- Which auth types work for Graph: ManagedIdentity, Federated, Certificate, ClientCredentials
- Token audience: https://graph.microsoft.com (or AzureUSGovernment: https://graph.microsoft.us, AzureChinaCloud: https://microsoftgraph.chinacloudapi.cn)
- Graph-specific auth notes: app-only context only. These scripts acquire tokens using the Graph resource endpoint with the default scope, and they do not implement delegated (user) flows.

## Endpoints
| Environment | Graph Endpoint |
|-------------|----------------|
| AzureCloud | https://graph.microsoft.com |
| AzureUSGovernment | https://graph.microsoft.us |
| AzureChinaCloud | https://microsoftgraph.chinacloudapi.cn |

## Skills
| File | Purpose |
|------|---------|
| Connect-GraphApi.ps1 | Resolves the selected Azure environment and returns a Graph auth context (token, expiry, Graph endpoint, and BaseUri) suitable for Invoke-GraphRequest. |
| Invoke-GraphRequest.ps1 | Invokes Microsoft Graph REST requests (relative Graph paths or absolute nextLink URLs), with optional @odata.nextLink pagination aggregation and throttling-aware retries. |
| auth/*.ps1 | Token acquisition wrappers for each supported auth type (ManagedIdentity, FederatedCredentials, CertificateBased, ClientCredentials), producing a Graph authentication context. |

## Toolchain
| Tool | Best For | Token Audience | Limitations in Graph Context |
|------|----------|----------------|-----------------------------|
| **Microsoft.Graph PowerShell SDK** (`Microsoft.Graph.*`) | Rich Graph entity coverage, strong typing, pagination handled automatically | `https://graph.microsoft.com/` (or gov/china equivalent) | Large module footprint; some beta endpoints lag behind REST API; app-only vs delegated context can be confusing |
| **Az PowerShell modules** (`Az.Accounts`) | Token chaining from Azure context to Graph | `https://graph.microsoft.com/` via `Get-AzAccessToken -ResourceTypeName MSGraph` | Limited to token acquisition; does not provide Graph SDK features |
| **Raw REST (`Invoke-RestMethod`)** | Full control over Graph API versions (beta, v1.0), headers, and query parameters | `https://graph.microsoft.com/` | Caller must handle pagination (`@odata.nextLink`), throttling (`Retry-After`), and token refresh manually |

## Patterns & Caveats
- Pagination: Invoke-GraphRequest supports -Paginate, which follows @odata.nextLink (default) and aggregates the response payload from the value property.
- Throttling: Invoke-GraphRequest retries on HTTP 429 and 5xx responses, and it uses the Retry-After response header when present.
- $select usage: Put $select in the -Uri query to reduce response payload size, especially for list endpoints you plan to paginate.
- App-only context requirements: tokens are acquired for the Graph resource endpoint (https://graph.microsoft.com or the sovereign equivalent). When you call Invoke-GraphRequest, your app registration must have the required application permissions for the operations you perform.

## Examples
```powershell
# 1) Managed identity: list users with $select and pagination
$context = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

$users = ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Uri "/users?`$select=id,displayName,mail" -Paginate
```

```powershell
# 2) Federated credentials: get a single group
$context = ./skills/graph/Connect-GraphApi.ps1 `
  -AuthenticationType Federated `
  -TenantId $env:AZURE_TENANT_ID `
  -ClientId $env:AZURE_CLIENT_ID `
  -FederatedToken $env:AZURE_FEDERATED_TOKEN `
  -Environment AzureCloud

$group = ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Uri "/groups/$groupId?`$select=id,displayName"
```

```powershell
# 3) Use an absolute nextLink URL directly
$context = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType Certificate -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -CertificatePath "/secure/certs/graph.pfx" -Environment AzureCloud

# First page (no aggregation)
$firstPage = ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Uri "/users?`$select=id,displayName&`$top=1"

# Second page, calling Invoke-GraphRequest with the absolute nextLink URL
$secondPage = ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Uri $firstPage."@odata.nextLink"
```

```powershell
# 4) Use a config.yaml profile
$context = ./skills/graph/Connect-GraphApi.ps1 -Profile "prod" -ConfigPath "./config.yaml"
```

```powershell
# 5) Use prefixed environment variables
$context = ./skills/graph/Connect-GraphApi.ps1 -Prefix "GOV" -Environment AzureUSGovernment
```

## Prerequisites
- Required modules: the skill scripts require PowerShell 7.2+. For certificate-based token acquisition, MSAL.PS is used if available; otherwise the scripts fall back to Azure CLI (az) for the access token.
- Required permissions (application permissions): configure Microsoft Graph application permissions on the app registration used by your auth method. The scripts request tokens for the Graph resource endpoint and then call Graph with that token.

## Related Docs
- [Auth Patterns](../docs/auth-patterns.md)
- [Token Chaining](../docs/token-chaining.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

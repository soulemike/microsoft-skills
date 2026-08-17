# Azure Resource Manager Skill

## Overview
This skill set covers Azure Resource Manager (ARM) authentication and REST calls for sovereign cloud aware automation. Use `Connect-AzureApi.ps1` to build an ARM context, then `Invoke-AzureRestMethod.ps1` to execute and track ARM operations.

## Authentication
- Auth types for ARM: ManagedIdentity, Federated (OIDC), Certificate, ClientCredentials (client secret).
- Token audience: https://management.azure.com/ (use the environment's ARM endpoint, for example https://management.usgovcloudapi.net or https://management.chinacloudapi.cn).
- Notes on service principal vs managed identity for ARM
  - Service principal (certificate or client secret) uses Entra ID app authentication and must have appropriate RBAC permissions on the target scope.
  - Managed identity avoids credential material and relies on the platform to obtain the ARM token via IMDS or the local identity endpoint.

## Endpoints
| Environment | ARM Endpoint |
|-------------|--------------|
| AzureCloud | https://management.azure.com |
| AzureUSGovernment | https://management.usgovcloudapi.net |
| AzureChinaCloud | https://management.chinacloudapi.cn |

## Skills
| File | Purpose |
|------|---------|
| Connect-AzureApi.ps1 | Resolves the ARM endpoint for the selected environment and acquires a token using the normalized auth parameter set, returning a consistent ARM context (Token, ExpiresOn, TenantId, ClientId, ArmEndpoint/BaseUri). |
| Invoke-AzureRestMethod.ps1 | Executes ARM REST requests from a relative ARM URI (or full URL), adds `api-version` when provided, supports GET pagination via `-Paginate`, and captures async operation headers (Operation-Location, Azure-AsyncOperation, Location) for polling. |
| auth/*.ps1 | Thin wrappers around `Connect-AzureApi.ps1` for common auth shapes: `ManagedIdentity.ps1`, `FederatedCredentials.ps1` (OIDC), and `ServicePrincipal.ps1` (certificate or client secret). |

## Toolchain
| Tool | Best For | Token Audience | Limitations in ARM Context |
|------|----------|----------------|---------------------------|
| **Azure CLI** (`az`) | Cross-platform scripting, Bicep/ARM deployment, quick ad-hoc commands | `https://management.azure.com/` by default | Not available in all execution contexts (e.g., restricted containers); output parsing can be brittle |
| **Az PowerShell modules** (`Az.*`) | Native PowerShell pipelines, object-oriented output, Azure Resource Graph | `https://management.azure.com/` by default | Heavy module dependency tree; version conflicts between `Az` and `Microsoft.Graph` modules can occur |
| **Bicep / ARM Templates** | Declarative infrastructure; `what-if` validation; policy-driven compliance | ARM deployment identity (service principal or managed identity) | Imperative logic (loops, conditionals) is limited; no direct Graph or Dataverse integration |
| **Raw REST (`Invoke-RestMethod`)** | Full control over headers, body, and URI for custom ARM operations | `https://management.azure.com/` | Caller must handle pagination, throttling, retry logic, and token refresh manually |

## Patterns & Caveats
- Async operations (Azure-AsyncOperation header)
- Subscription scoping
- api-version requirements
- ARM template deployment vs direct REST

## Examples
1) List resource groups (GET, with pagination)
```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud -SubscriptionId $env:SUBSCRIPTION_ID

$result = ./skills/azure/Invoke-AzureRestMethod.ps1 `
  -Uri "/subscriptions/$($ctx.SubscriptionId)/resourcegroups" `
  -ApiVersion '2021-04-01' `
  -AuthContext $ctx `
  -Paginate

$result.Value | Select-Object -First 10
```

2) Run a PUT that returns async metadata (capture operation URLs)
```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType Certificate -Environment AzureCloud -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -CertificatePath "/secure/certs/automation.pfx" -SubscriptionId $env:SUBSCRIPTION_ID

$payload = @{
  location = 'eastus'
  kind      = 'StorageV2'
  sku       = @{ name = 'Standard_LRS' }
}

$resp = ./skills/azure/Invoke-AzureRestMethod.ps1 `
  -Method PUT `
  -Uri "/subscriptions/$($ctx.SubscriptionId)/resourceGroups/$env:RG/providers/Microsoft.Storage/storageAccounts/$env:STORAGEACCOUNTNAME" `
  -ApiVersion '2023-05-01' `
  -Body $payload `
  -AuthContext $ctx

# Use one of these for polling, depending on what the service returns
$resp.OperationLocation
$resp.AzureAsyncOperation
$resp.Location
```

3) Poll async status using the captured Azure-AsyncOperation URL
```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType Federated -Environment AzureCloud -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -FederatedToken $env:AZURE_FEDERATED_TOKEN -SubscriptionId $env:SUBSCRIPTION_ID

$put = ./skills/azure/Invoke-AzureRestMethod.ps1 -Method PUT -Uri "/subscriptions/$($ctx.SubscriptionId)/resourceGroups/$env:RG/providers/Microsoft.Resources/deployments/$env:DEPLOYMENTNAME" -ApiVersion '2021-04-01' -Body @{ properties = @{ mode = 'Incremental'; templateLink = @{ uri = $env:TEMPLATE_URI } } } -AuthContext $ctx

$pollUri = $put.AzureAsyncOperation
while ($pollUri) {
  Start-Sleep -Seconds 5
  $status = ./skills/azure/Invoke-AzureRestMethod.ps1 -Method GET -Uri $pollUri -AuthContext $ctx
  $state = $status.Value.status
  if ($state -in @('Succeeded','Failed')) { break }
  $pollUri = $null  # if the server stopped returning an async URL, fall out
}
```

```powershell
# 4) Use a config.yaml profile
$ctx = ./skills/azure/Connect-AzureApi.ps1 -Profile "prod" -ConfigPath "./config.yaml"
```

```powershell
# 5) Use prefixed environment variables
$ctx = ./skills/azure/Connect-AzureApi.ps1 -Prefix "GOV" -Environment AzureUSGovernment
```

## Prerequisites
- Required modules: PowerShell 7.2+, `MSAL.PS` (recommended for certificate token acquisition, used by `Common.psm1`), Azure CLI `az` if `MSAL.PS` is unavailable for certificate flows.
- Required roles: RBAC permissions on the target scope (subscription or resource group), for example `Reader` for read-only operations, `Contributor` or higher for PUT/PATCH/DELETE, and deployment permissions for ARM template deployments.

## Related Docs
- [Auth Patterns](../docs/auth-patterns.md)
- [Token Chaining](../docs/token-chaining.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

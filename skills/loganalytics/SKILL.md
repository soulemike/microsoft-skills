# Log Analytics Workspace Lifecycle Skill

## Overview
This skill set manages Log Analytics workspace lifecycle operations across the Azure Resource Manager (ARM) management plane and Azure Monitor ingestion endpoints. It standardizes authentication, workspace provisioning, custom table creation, Data Collection Endpoint (DCE) and Data Collection Rule (DCR) setup, and log ingestion with a DCR-first strategy.

The preferred ingestion path is the Logs Ingestion API through a DCE and DCR. When that path fails with HTTP 401 or 403 because the caller lacks the required DCR role assignment or the token is not accepted by the ingestion endpoint, the skill can gracefully fall back to the legacy HTTP Data Collector API if a workspace shared key is available.

## Authentication
- Log Analytics query/data-plane token audience: `LogAnalyticsTokenAudience` from `Get-EnvironmentEndpoints`
- Log Analytics query/data-plane request endpoint: `LogAnalytics` from `Get-EnvironmentEndpoints`
- Azure Monitor Logs Ingestion token audience for DCR-based uploads: `https://monitor.azure.com/` in AzureCloud, `https://monitor.azure.us/` in AzureUSGovernment, and `https://monitor.azure.cn/` in AzureChinaCloud
- Workspace lifecycle operations use ARM request URIs and therefore require an ARM-capable bearer token in the supplied `AuthContext`
- Logs Ingestion API requests use the caller's supplied bearer token against the DCE ingestion endpoint
- Data Collector API fallback uses the workspace shared key instead of Entra bearer authentication

> **Important:** The Log Analytics query/data-plane token audience and the request endpoint are different values. Use `LogAnalyticsTokenAudience` to acquire a token and `LogAnalytics` as the `BaseUri` for Log Analytics data-plane connections. For ARM lifecycle operations, supply an ARM-scoped context such as the output of `skills/azure/Connect-AzureApi.ps1`.

> **Important:** DCR-based log ingestion uses the Azure Monitor Logs Ingestion API, not the Log Analytics query API. `Send-LogAnalyticsData.ps1` expects a monitor-scoped bearer token in `AuthContext` for non-managed-identity flows. Managed identity is the only flow the script attempts to re-acquire automatically for the correct ingestion audience.

## Endpoints
| Plane | Request Endpoint | Authentication |
|-------|------------------|----------------|
| Log Analytics query/data plane | `https://api.loganalytics.azure.com/` | Bearer token for `LogAnalyticsTokenAudience` |
| Workspace lifecycle / tables / DCE / DCR | `https://management.azure.com/` | ARM bearer token |
| Logs Ingestion API | `https://{dce}.{region}-1.ingest.monitor.azure.com/` | Bearer token for the Azure Monitor ingestion audience for the selected cloud |
| HTTP Data Collector API fallback | `https://{workspace-id}.{cloud-specific-ods-host}/api/logs` | Shared-key signature |

## Skills
| File | Purpose |
|------|---------|
| Connect-LogAnalyticsApi.ps1 | Creates a Log Analytics data-plane authentication context using `LogAnalyticsTokenAudience` and `LogAnalytics` |
| Invoke-LogAnalyticsKqlQuery.ps1 | Executes a KQL query against a Log Analytics workspace and converts tabular results into PowerShell objects |
| New-LogAnalyticsWorkspace.ps1 | Creates or reuses a Log Analytics workspace via ARM and returns workspace metadata plus the primary shared key |
| New-LogAnalyticsCustomTable.ps1 | Creates or updates a custom table schema in a workspace via ARM |
| New-LogAnalyticsIngestionPipeline.ps1 | Provisions a DCE and a starter DCR targeting the workspace and attempts DCR role assignment |
| Send-LogAnalyticsData.ps1 | Sends logs through the DCR ingestion path first, then falls back to the Data Collector API on 401/403 |
| auth/*.ps1 | Thin auth wrappers for managed identity, federated credentials, certificate-based auth, and client credentials |

## Workspace Lifecycle Capabilities
### Workspace creation via ARM
- Creates the workspace under `Microsoft.OperationalInsights/workspaces`
- Checks whether the workspace already exists before issuing a create request
- Retrieves `customerId` and the primary shared key after creation or reuse
- Returns enough metadata for later ingestion steps

### Custom table creation via ARM
- Uses `Microsoft.OperationalInsights/workspaces/tables`
- Accepts schema column definitions as hashtables with `name`, `type`, and `description`
- Supports repeatable execution so table schema creation can be automated as part of bootstrap flows
- The starter ingestion pipeline created by this skill writes to `Custom-LogAnalyticsRaw_CL` unless you customize the DCR outside this script

### DCE and DCR provisioning via ARM
- Creates the DCE first so the DCR can reference it
- Creates a starter direct-ingestion DCR that targets the workspace
- Returns the DCE ingestion URI and DCR immutable ID needed by the Logs Ingestion API
- Attempts to assign the `Monitoring Metrics Publisher` role on the DCR to the calling service principal or managed identity when the caller token exposes an `oid` claim

## Ingestion Strategy
### Primary path: Logs Ingestion API
- Preferred for modern ingestion scenarios
- Requires a DCE URI and DCR immutable ID
- Requires an Azure Monitor ingestion token, not a Log Analytics query token and not a generic ARM token
- Requires the caller to have the `Monitoring Metrics Publisher` role on the DCR
- Uses the stream path:
  `https://{dce-uri}/dataCollectionRules/{dcr-immutableId}/streams/{stream}?api-version=2023-01-01`

### Fallback path: HTTP Data Collector API
- Used automatically only when the DCR ingestion attempt fails with HTTP 401 or 403
- Requires the workspace shared key
- Signs the request with the shared key and posts newline-delimited JSON to the correct cloud-specific ODS host for the selected environment
- Useful when DCR role assignment cannot be completed or the caller lacks permission to use the DCR path
- `Send-LogAnalyticsData.ps1` accepts an optional `-DataCollectorLogType` so callers can explicitly control the fallback table mapping when the stream name is not sufficient

## Role Assignments and Permissions
- **Workspace provisioning and custom tables:** `Log Analytics Contributor` is the expected baseline role for workspace-scoped ARM lifecycle operations
- **DCR-based ingestion:** `Monitoring Metrics Publisher` on the DCR is required for the caller identity that posts to the Logs Ingestion API
- **Role assignment creation:** the caller also needs `Microsoft.Authorization/roleAssignments/*` permission to create the DCR role assignment

If the skill can create the DCR but cannot create the role assignment, it does **not** fail the pipeline bootstrap. Instead it:
- emits a warning explaining that role assignment permissions are missing or insufficient
- returns the DCE URI and DCR immutable ID anyway
- allows `Send-LogAnalyticsData.ps1` to auto-fallback to the Data Collector API when the DCR path later returns 401 or 403 and a workspace shared key is available

## Patterns and Caveats
- Distinguish query/data-plane Log Analytics auth from ARM lifecycle auth
- DCR ingestion and Data Collector ingestion are different protocols with different auth models
- A bearer token can be valid for one endpoint and still be rejected by the DCR ingestion endpoint
- Shared-key fallback is intentionally limited to 401/403 cases so genuine payload or configuration problems still surface clearly
- The starter DCR created by this skill is intended to bootstrap direct ingestion and may need to be tailored further for production stream declarations and transformations

## Examples
### Connect to Log Analytics data plane
```powershell
$logAnalyticsContext = ./skills/loganalytics/Connect-LogAnalyticsApi.ps1 `
  -AuthenticationType ManagedIdentity `
  -Environment AzureCloud
```

### Run a KQL query
```powershell
./skills/loganalytics/Invoke-LogAnalyticsKqlQuery.ps1 `
  -WorkspaceId "00000000-0000-0000-0000-000000000000" `
  -Query "SecurityIncident | take 10" `
  -Timespan "1d" `
  -AuthContext $logAnalyticsContext
```

### Create or reuse a workspace
```powershell
$armContext = ./skills/azure/Connect-AzureApi.ps1 `
  -AuthenticationType ManagedIdentity `
  -Environment AzureCloud `
  -SubscriptionId $subscriptionId

$workspace = ./skills/loganalytics/New-LogAnalyticsWorkspace.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -WorkspaceName $workspaceName `
  -Location 'eastus' `
  -AuthContext $armContext
```

### Create a custom table
```powershell
$table = ./skills/loganalytics/New-LogAnalyticsCustomTable.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -WorkspaceName $workspaceName `
  -TableName 'Custom-LogAnalyticsRaw_CL' `
  -SchemaColumns @(
      @{ name = 'TimeGenerated'; type = 'dateTime'; description = 'Event timestamp' }
      @{ name = 'RawData'; type = 'string'; description = 'Raw log payload' }
  ) `
  -AuthContext $armContext
```

### Provision DCE and DCR
```powershell
$pipeline = ./skills/loganalytics/New-LogAnalyticsIngestionPipeline.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -WorkspaceResourceId $workspace.ResourceId `
  -Location 'eastus' `
  -DataCollectionEndpointName 'contoso-la-dce' `
  -DataCollectionRuleName 'contoso-la-dcr' `
  -AuthContext $armContext
```

### Send data with automatic fallback
```powershell
$ingestionAuthContext = ./prerequisites/Setup-AuthenticationContext.ps1 -Resource 'https://monitor.azure.com/'

./skills/loganalytics/Send-LogAnalyticsData.ps1 `
  -WorkspaceId $workspace.CustomerId `
  -WorkspaceSharedKey $workspace.PrimarySharedKey `
  -DceUri $pipeline.DceUri `
  -DcrImmutableId $pipeline.DcrImmutableId `
  -StreamName 'Custom-LogAnalyticsRaw' `
  -Data @(
      [pscustomobject]@{ TimeGenerated = (Get-Date).ToUniversalTime(); RawData = 'hello world' }
  ) `
  -DataCollectorLogType 'Custom-LogAnalyticsRaw' `
  -AuthContext $ingestionAuthContext
```

## Prerequisites
- PowerShell 7.2+
- `skills/Common.psm1`
- ARM permission to create Log Analytics workspaces, tables, DCEs, and DCRs
- `Log Analytics Contributor` for workspace lifecycle work
- `Monitoring Metrics Publisher` on the DCR for DCR-based ingestion
- Optional shared-key access for Data Collector API fallback

## Related Docs
- [Auth Patterns](../docs/auth-patterns.md)
- [Token Chaining](../docs/token-chaining.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

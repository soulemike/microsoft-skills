# Microsoft Sentinel Skill

## Overview
This skill set runs Microsoft Sentinel operations on the management plane via ARM (`Microsoft.SecurityInsights` resources). It wraps authentication and request execution so you can manage incidents, alert rules, watchlists, automation rules, and data connectors consistently.

For Log Analytics data-plane operations such as KQL queries, custom table creation, workspace provisioning, and log ingestion, see the [`loganalytics` skill](../loganalytics/SKILL.md).

## Authentication
- Management plane: ARM token (`https://management.azure.com/`)
- The Log Analytics query/data-plane token is separate; use the `loganalytics` skill for KQL queries and ingestion

## Endpoints
| Plane | Request Endpoint | Token Audience |
|--------|-----------------|----------------|
| Management (ARM) | `https://management.azure.com/` | `https://management.azure.com/` |

## Skills
| File | Purpose |
|------|---------|
| Invoke-SentinelArmRequest.ps1 | Calls workspace-scoped Microsoft Sentinel ARM resources under `Microsoft.SecurityInsights` and supports pagination (nextLink) |
| Get-SentinelIncident.ps1 | Retrieves Sentinel incidents via ARM, including optional status filtering and multi-page enumeration |
| Get-SentinelAlertRule.ps1 | Enumerates Sentinel analytic alert rules via ARM, including optional lookup by rule ID |

## Toolchain
| Plane | Tool | Best For | Token Audience | Limitations |
|-------|------|----------|----------------|-------------|
| **Management** | **Az.SecurityInsights** (`Get-AzSentinelIncident`, `New-AzSentinelAlertRule`) | Native PowerShell for incidents, alert rules, watchlists, automation rules | `https://management.azure.com/` | Module dependency; not all preview features available |
| **Management** | **Azure CLI** (`az sentinel`) | Incident, watchlist, and automation rule management | `https://management.azure.com/` | Extension-based; may lag behind latest ARM API versions |
| **Management** | **Raw REST / ARM** (`Invoke-AzRestMethod`) | Full control over Sentinel ARM resources | `https://management.azure.com/` | Caller must construct ARM paths and handle async operations |

> For KQL queries, workspace lifecycle, custom tables, DCE/DCR provisioning, and log ingestion, use the [`loganalytics` skill](../loganalytics/SKILL.md).

## Patterns & Caveats
- ARM async operations
- Key ARM paths (alertRules, watchlists, incidents, automationRules, dataConnectors)

## Examples
### Incident retrieval
```powershell
./skills/sentinel/Get-SentinelIncident.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -WorkspaceName $workspaceName `
  -Status "Active" `
  -AuthContext $authContext
```

### Alert rule enumeration
```powershell
./skills/sentinel/Get-SentinelAlertRule.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -WorkspaceName $workspaceName `
  -AuthContext $authContext
```

## Prerequisites
- Required modules
  - PowerShell 7.2+
  - MSAL.PS (only if you use certificate-based authentication and want MSAL token acquisition without Azure CLI fallback)
- Required roles
  - Microsoft Sentinel Reader (for viewing incidents and analytic rules)
  - Microsoft Sentinel Contributor (required if you perform management-plane write operations via ARM, for example when expanding this skill set beyond read-only retrieval)

## Related Docs
- [Auth Patterns](../docs/auth-patterns.md)
- [Token Chaining](../docs/token-chaining.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

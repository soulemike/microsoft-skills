---
name: sentinel
description: Use this skill for Microsoft Sentinel management-plane automation over Azure Resource Manager, including incidents and analytic rules.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - sentinel
  - security
  - siem
  - azure
  - powershell
metadata:
  project: microsoft-cloud-api-skills
  domain: sentinel
---

# Microsoft Sentinel Skill

## Agent Summary
Use this skill for Microsoft Sentinel management-plane tasks that run through the `Microsoft.SecurityInsights` ARM provider. You must supply an ARM-capable auth context, usually created by `./skills/azure/Connect-AzureApi.ps1`.

## When to Use
- List or retrieve Sentinel incidents from a workspace.
- Enumerate analytic alert rules through ARM.
- Call workspace-scoped Sentinel management endpoints when no higher-level wrapper exists.

## Required Parameters
### `Get-SentinelIncident.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `SubscriptionId` | `string` | Yes | Azure subscription hosting the workspace. |
| `ResourceGroupName` | `string` | Yes | Resource group containing the workspace. |
| `WorkspaceName` | `string` | Yes | Sentinel-enabled Log Analytics workspace. |
| `AuthContext` | `hashtable` | Yes | ARM auth context, typically from `Connect-AzureApi.ps1`. |
| `IncidentId` | `string` | No | Retrieve one incident instead of listing all. |
| `Status` | `string` | No | Client-side filter such as `New`, `Active`, or `Closed`. |

### `Get-SentinelAlertRule.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `SubscriptionId` | `string` | Yes | Azure subscription hosting the workspace. |
| `ResourceGroupName` | `string` | Yes | Resource group containing the workspace. |
| `WorkspaceName` | `string` | Yes | Sentinel-enabled Log Analytics workspace. |
| `AuthContext` | `hashtable` | Yes | ARM auth context. |
| `RuleId` | `string` | No | Retrieve one rule instead of listing all. |

### `Invoke-SentinelArmRequest.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Uri` | `string` | Yes | Relative path like `/incidents` or absolute `nextLink`. |
| `SubscriptionId` | `string` | Yes | Azure subscription hosting the workspace. |
| `ResourceGroupName` | `string` | Yes | Resource group containing the workspace. |
| `WorkspaceName` | `string` | Yes | Sentinel-enabled Log Analytics workspace. |
| `AuthContext` | `hashtable` | Yes | ARM auth context. |
| `Method` | `string` | No | Defaults to `GET`. |
| `ApiVersion` | `string` | No | Defaults to `2024-03-01`. |

## Example Agent Prompts
- "Query all Sentinel incidents from the last 24 hours."
- "List all analytic alert rules for this Sentinel workspace."
- "Call the Sentinel ARM incidents endpoint directly and return every page."

## Example Agent Workflow
```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud -SubscriptionId $subscriptionId

$incidents = ./skills/sentinel/Get-SentinelIncident.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -AuthContext $ctx -Status Active
```

## Security Caveats
- Use an ARM context with the least privilege required, such as `Microsoft Sentinel Reader` for read-only workflows.
- Do not confuse Sentinel management-plane access with Log Analytics data-plane access; KQL belongs to the `loganalytics` skill.
- Avoid client secret auth in production when managed identity or federated credentials are available.

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
- [Auth Patterns](../../docs/auth-patterns.md)
- [Token Chaining](../../docs/token-chaining.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)

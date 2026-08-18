---
name: intune
description: Use this skill for Microsoft Intune device and configuration policy retrieval through Microsoft Graph, including per-item enrichment and beta-only policy surfaces.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - intune
  - endpoint-manager
  - graph
  - powershell
  - device-management
metadata:
  project: microsoft-cloud-api-skills
  domain: intune
---

# Intune / Endpoint Manager Skill

## Agent Summary
Use this skill when an agent needs Intune data through Microsoft Graph, especially when list endpoints return incomplete objects. The usual pattern is to authenticate with `./skills/graph/Connect-GraphApi.ps1`, list lightweight objects first, then perform per-item GETs or child-endpoint queries for full detail.

## When to Use
- List Intune managed devices and enrich sparse properties.
- Retrieve classic device configuration or compliance policies.
- Access beta-only settings catalog or configuration policy endpoints.

## Required Parameters
### `Get-IntuneDevice.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `AuthContext` | `hashtable` | Yes | Graph auth context from `Connect-GraphApi.ps1`. |
| `DeviceId` | `string` | No | When present, retrieves one managed device. |
| `Select` | `string[]` | No | Use this for per-device enrichment; `hardwareInformation` forces beta. |

### `Get-IntuneConfigurationPolicy.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `AuthContext` | `hashtable` | Yes | Graph auth context from `Connect-GraphApi.ps1`. |
| `PolicyType` | `string` | No | `deviceConfiguration`, `deviceCompliance`, or `configurationPolicy`; defaults to `deviceConfiguration`. |
| `PolicyId` | `string` | No | Retrieve one policy instead of listing. |
| `IncludeSettings` | `switch` | No | Valid only for `configurationPolicy`. |
| `IncludeAssignments` | `switch` | No | Retrieves `/assignments` child data. |

### `Invoke-IntuneGraphRequest.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Uri` | `string` | Yes | Intune-relative path or absolute Graph nextLink URL. |
| `AuthContext` | `hashtable` | Yes | Graph auth context. |
| `ApiVersion` | `string` | No | `v1.0` or `beta`; defaults to `v1.0`. |
| `Method` | `string` | No | Defaults to `GET`. |
| `Body` | `object` | No | Request payload for writes. |

## Example Agent Prompts
- "List all Intune managed devices and then enrich each device with hardware information."
- "Retrieve all Intune configuration policies including settings and assignments."
- "Use the beta Intune endpoint for settings catalog policies."

## Example Agent Workflow
```powershell
$ctx = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

$devices = ./skills/intune/Get-IntuneDevice.ps1 -AuthContext $ctx -Select @('id','deviceName','operatingSystem')
```

## Security Caveats
- Prefer managed identity or federated credentials over client secrets.
- Request only the Graph application permissions needed for the exact Intune surface you are querying.
- Treat beta endpoints as change-prone and validate them before using them in production automations.

## Overview
This skill package uses Microsoft Graph to read Intune managed devices and retrieve Intune policy configuration details.

When collection endpoints return incomplete objects, it uses per-item GET enrichment and child-endpoint lookups.

## Authentication
- Graph token
- v1.0 for classic operations
- beta required for modern operations

## Endpoints
Uses Graph endpoint from environment.

## Skills
| File | Purpose |
|------|---------|
| Get-IntuneDevice.ps1 | Lists Intune managed devices and, when needed, enriches per-device fields via item GET and `$select` |
| Get-IntuneConfigurationPolicy.ps1 | Retrieves Intune device configuration policies, classic policies, and modern configuration policy settings via beta child endpoints |
| Invoke-IntuneGraphRequest.ps1 | Intune-aware Graph REST wrapper, supporting v1.0 and `beta`, with automatic pagination for GETs |

## Toolchain
| Service | Tool | Best For | Graph Version | Limitations |
|---------|------|----------|---------------|-------------|
| **Teams** | **Microsoft.Graph SDK** (`Get-MgTeam`, `Get-MgTeamChannel`) | Team/channel lifecycle, messages, tabs, apps | `v1.0` | Large module footprint; some operations require Group.ReadWrite.All |
| **Teams** | **Raw REST** (`Invoke-MgGraphRequest`) | Direct control over Teams endpoints | `v1.0` / `beta` | Caller must handle pagination and throttling |
| **Teams** | **PnP CLI** (`m365 teams`) | Cross-platform Teams admin scripting | `v1.0` | Community-driven; no Microsoft SLA |
| **Intune** | **Microsoft.Graph** SDK (`Get-MgDeviceManagementDeviceConfiguration`) | Classic device configuration, compliance policies, managed devices | `v1.0` | Settings catalog and modern policies not in v1.0 |
| **Intune** | **Raw REST** (this toolkit) | Direct access to any Intune endpoint via `Invoke-IntuneGraphRequest.ps1` | `v1.0` / `beta` | Must explicitly target `-ApiVersion beta` for modern policy operations; caller handles pagination and throttling |

## Patterns & Caveats
### List vs Get Is Not Symmetric
The list response returns default, null, or empty values for several properties. A per-device `GET /{id}` with `$select` is required to retrieve true values.

| Property | List Behavior | Per-Device GET Required |
|----------|---------------|------------------------|
| `activationLockBypassCode` | `null` | Yes, with `$select` |
| `hardwareInformation` | Omitted / default | Yes, with `$select` (beta) |
| `notes` | `null` | Yes, with `$select` |
| `iccid` | Empty string | Yes, with `$select` |
| `udid` | Empty string | Yes, with `$select` |
| `ethernetMacAddress` | `null` / default | Yes, with `$select` |
| `physicalMemoryInBytes` | `0` | Yes, with `$select` |
| `remoteAssistanceSessionUrl` | Empty string | Yes, with `$select` |

**Recommended Pattern**

```powershell
# 1. List to get IDs
$devices = Invoke-GraphRequest -Uri "deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem"

# 2. Iterate and enrich per device
foreach ($device in $devices.value) {
    $detail = Invoke-GraphRequest -Uri "deviceManagement/managedDevices/$($device.id)?`$select=id,activationLockBypassCode,hardwareInformation,notes"
}
```

`$select` mitigates this on item GETs, but does not make collection endpoints return true values for these properties.

### Beta-Required Capabilities
- Settings catalog
- Assignment filters
- Reusable settings
- Device health scripts

### Policy Detail Lives in Child Endpoints
Policy list responses contain the policy object metadata, but operational detail lives in child endpoints. This is a related collection pattern rather than a sparse-item pattern.

| Endpoint Type | List Returns | Child Endpoints for Detail |
|---------------|--------------|---------------------------|
| `deviceConfigurations` | Policy metadata (`id`, `displayName`, `platform`, `version`) | `/{id}/assignments`, `/{id}/deviceStatuses`, `/{id}/getOmaSettingPlainTextValue(...)` |
| `deviceCompliancePolicies` | Policy metadata | `/{id}/assignments`, `/{id}/scheduledActionsForRule`, `/{id}/scheduledActionsForRule/{ruleId}/scheduledActionConfigurations` |
| `configurationPolicies` (beta) | Policy metadata (`id`, `name`, `settingCount`, `templateReference`) | `/{id}/settings`, `/{id}/settings?$expand=settingDefinitions`, `/{id}/assignments` |

**Recommended Pattern**

```powershell
# 1. List policies
$policies = Invoke-GraphRequest -Uri "deviceManagement/configurationPolicies"

# 2. Per policy, fetch settings and assignments
foreach ($policy in $policies.value) {
    $settings = Invoke-GraphRequest -Uri "deviceManagement/configurationPolicies/$($policy.id)/settings?`$expand=settingDefinitions"
    $assignments = Invoke-GraphRequest -Uri "deviceManagement/configurationPolicies/$($policy.id)/assignments"
}
```

**Key Takeaway**: `$expand` is not a universal fix. For managed devices, use `$select` on per-item GETs. For policies, follow child endpoints. Always paginate both list and child collection calls.

## Examples
1) List+enrich managed device details (use item GET for sparse fields)

```powershell
$context = Connect-GraphApi -AuthenticationType ManagedIdentity -Environment AzureCloud

# 1. List with a lightweight projection
$devices = Get-IntuneDevice -AuthContext $context -Select @('id','deviceName','operatingSystem')

# 2. Enrich per device
foreach ($d in $devices) {
    $detail = Get-IntuneDevice -AuthContext $context -DeviceId $d.id -Select @('id','activationLockBypassCode','hardwareInformation','notes')
    $detail
}
```

2) Use the beta endpoint explicitly for modern Intune policy surfaces

```powershell
$context = Connect-GraphApi -AuthenticationType ManagedIdentity -Environment AzureCloud

# Beta is required for modern configuration policies and settings catalog surfaces
$configurationPolicies = Invoke-IntuneGraphRequest -AuthContext $context -Uri '/configurationPolicies' -ApiVersion beta
$configurationPolicies
```

3) Retrieve policy settings via child endpoints (`/settings`) and include assignments

```powershell
$context = Connect-GraphApi -AuthenticationType ManagedIdentity -Environment AzureCloud

$policies = Get-IntuneConfigurationPolicy -AuthContext $context -PolicyType configurationPolicy -IncludeSettings -IncludeAssignments
$policies[0].settings
$policies[0].assignments
```

## Prerequisites
- Required modules
  - PowerShell 7.2+
  - `Microsoft.Graph.Authentication`, `Microsoft.Graph.DeviceManagement` (installed by `./prerequisites/Install-RequiredModules.ps1`)
  - `MSAL.PS` only if using certificate authentication
- Required permissions
  - Managed devices: `DeviceManagementManagedDevices.Read.All` (or `DeviceManagementManagedDevices.ReadWrite.All`)
  - Configuration and settings catalog: `DeviceManagementConfiguration.Read.All` (or `DeviceManagementConfiguration.ReadWrite.All`), plus `DeviceManagementEndpointSecurity.Read.All` (or `DeviceManagementEndpointSecurity.ReadWrite.All`) when required by the endpoint
  - Device health scripts: `DeviceManagementScripts.Read.All` (or `DeviceManagementScripts.ReadWrite.All`)

## Community Resources

### IntuneAutomation

[IntuneAutomation](https://www.intuneautomation.com/) is an open-source Intune PowerShell script library maintained by [UgurLabs](https://ugurlabs.com). It provides 60 production-ready scripts covering devices, compliance, apps, security, reporting, operational tasks, configuration, monitoring, diagnostics, notification, and remediation.

| Attribute | Detail |
|-----------|--------|
| **License** | MIT |
| **Validation** | PSScriptAnalyzer in CI |
| **Execution modes** | Local PowerShell or Azure Automation runbook |
| **Auth method** | Interactive or app-only via `Invoke-MgGraphRequest` |
| **Graph version** | v1.0 and beta |

**Relationship to this skill:** IntuneAutomation is a **complementary domain-specific script library**, not a competitor. It offers breadth (60 ready-to-run scripts) without the cross-service auth governance, secret management, or multi-tenant isolation patterns this toolkit enforces. Teams using this toolkit for auth governance can port IntuneAutomation scripts into the normalized parameter set by replacing their auth blocks with `Connect-GraphApi.ps1` and their REST calls with `Invoke-IntuneGraphRequest.ps1`.

**Companion tools from the same maintainer:**
- [IntuneBrew](https://intunebrew.com/) — macOS app packaging and deployment via Homebrew
- [IntuneGet](https://intuneget.com/) — Windows app packaging and deployment automation
- [TenuVault](https://tenuvault.com/) — Tenant-level backup and restore for Intune policies, profiles, and apps

## Related Docs
- [Auth Patterns](../../docs/auth-patterns.md)
- [Patterns and Caveats](../../docs/patterns-and-caveats.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)

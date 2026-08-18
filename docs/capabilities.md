# Capability Overview

> What your agent can do with this toolkit.

## Security & Operations

| | |
|---|---|
| **Sentinel** | List incidents, alert rules, and watchlists. Triage security events programmatically. |
| **Log Analytics** | Run KQL queries, manage workspaces, provision DCE/DCR pipelines, send custom data. |
| **Intune** | List devices, configuration policies, and compliance status. Manage endpoint posture. |

## Identity & Collaboration

| | |
|---|---|
| **Microsoft Graph** | Query users, groups, applications, service principals. Automate identity workflows. |
| **Teams** | List channels and members. Automate team governance. |

## Platform & Infrastructure

| | |
|---|---|
| **Azure ARM** | Manage resources, resource groups, deployments. Handle async operations. |
| **VM Guest Management** | Execute run commands, connect via Bastion SSH, rotate SSH keys. |
| **Power Platform** | List environments, manage BAP API resources. |
| **Dataverse** | Query entities via OData, discover environments, manage Copilot Studio agents. |
| **Copilot Studio** | Deploy, publish, and update agents. Manage knowledge sources. |

## Authentication & Governance

| | |
|---|---|
| **Auto-detect auth** | `Setup-AuthenticationContext.ps1` probes Managed Identity → Federated → Certificate → Secret. |
| **Multi-tenant safe** | Use `-Prefix` or `-Profile` to isolate contexts. Never accidentally cross tenants. |
| **Secret hierarchy** | Managed Identity preferred. Client secrets trigger runtime warnings. No embedded secrets. |
| **Sovereign cloud** | Built-in support for AzureCloud, AzureUSGovernment, and AzureChinaCloud. |

## Quick Reference

```powershell
# Sentinel incidents
./skills/sentinel/Get-SentinelIncident.ps1 -AuthContext $ctx -WorkspaceName "sec-ops"

# KQL query
./skills/loganalytics/Invoke-LogAnalyticsKqlQuery.ps1 `
    -AuthContext $laCtx -WorkspaceId "..." -Query "SecurityAlert | take 10"

# Intune devices
./skills/intune/Get-IntuneDevice.ps1 -AuthContext $graphCtx

# Graph users
./skills/graph/Invoke-GraphRequest.ps1 -Context $graphCtx -Uri "/users?`$top=10"

# Dataverse accounts
./skills/dataverse/Invoke-DataverseRequest.ps1 -AuthContext $dvCtx -Uri "/accounts?`$top=50"

# VM run command
./skills/vm-guest-management/Invoke-VmRunCommand.ps1 `
    -AuthContext $azureCtx -ResourceGroupName "rg" -VMName "vm" -Command "Get-Process"
```

See per-service [`SKILL.md`](skills/graph/SKILL.md) files for detailed patterns and caveats.

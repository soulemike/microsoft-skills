# Agent Contract — Microsoft Cloud API Skills

> This file is a machine-readable contract for AI coding agents. It describes the tools, auth patterns, and security boundaries available in this repository.

## Project Identity

- **Name:** Microsoft Cloud API Skills
- **Type:** PowerShell-native automation toolkit
- **Scope:** Unified authentication and API interaction for Microsoft Graph, Azure ARM, Sentinel, Log Analytics, Intune, Teams, Dataverse, Power Platform, Copilot Studio, and VM Guest Management
- **License:** MIT
- **Repository:** https://github.com/microsoft/cloud-api-skills

## Agent Capabilities

Your agent can use this toolkit to:

1. **Authenticate securely** to any Microsoft cloud service using a unified auth hierarchy
2. **Query and manage** Azure resources, Entra ID objects, Sentinel incidents, Intune devices, Teams channels, Dataverse entities, and more
3. **Run KQL queries** against Log Analytics workspaces
4. **Deploy and manage** Copilot Studio agents via Dataverse
5. **Execute VM run commands** and manage SSH keys securely

## Tool Inventory

### Connection Tools (Auth)

| Tool | Script Path | Purpose | Required Params | Optional Params |
|------|-------------|---------|-----------------|-----------------|
| `connect_graph` | `skills/graph/Connect-GraphApi.ps1` | Auth to Microsoft Graph | `-AuthenticationType`, `-Environment` | `-TenantId`, `-ClientId`, `-FederatedToken`, `-CertificatePath` |
| `connect_azure` | `skills/azure/Connect-AzureApi.ps1` | Auth to Azure ARM | `-AuthenticationType`, `-Environment` | `-TenantId`, `-ClientId`, `-SubscriptionId` |
| `connect_loganalytics` | `skills/loganalytics/Connect-LogAnalyticsApi.ps1` | Auth to Log Analytics | `-AuthenticationType`, `-Environment` | `-TenantId`, `-ClientId` |
| `connect_dataverse` | `skills/dataverse/Connect-DataverseApi.ps1` | Auth to Dataverse | `-AuthenticationType`, `-EnvironmentUrl` | `-TenantId`, `-ClientId` |
| `connect_powerplatform` | `skills/powerplatform/Connect-PowerPlatformApi.ps1` | Auth to Power Platform BAP | `-AuthenticationType`, `-Environment` | `-TenantId`, `-ClientId` |
| `setup_auth_context` | `prerequisites/Setup-AuthenticationContext.ps1` | Auto-detect best auth method | `-Resource` | — |

### Invocation Tools (Data Plane)

| Tool | Script Path | Purpose | Context Required |
|------|-------------|---------|------------------|
| `invoke_graph_request` | `skills/graph/Invoke-GraphRequest.ps1` | Call any Graph API endpoint | Graph auth context |
| `invoke_azure_rest` | `skills/azure/Invoke-AzureRestMethod.ps1` | Call any Azure ARM endpoint | Azure auth context |
| `invoke_loganalytics_kql` | `skills/loganalytics/Invoke-LogAnalyticsKqlQuery.ps1` | Run KQL query | Log Analytics auth context |
| `invoke_dataverse_request` | `skills/dataverse/Invoke-DataverseRequest.ps1` | Call Dataverse Web API | Dataverse auth context |
| `invoke_sentinel_arm` | `skills/sentinel/Invoke-SentinelArmRequest.ps1` | Sentinel management plane | Azure auth context |

### Specialized Tools

| Tool | Script Path | Purpose | Context Required |
|------|-------------|---------|------------------|
| `get_sentinel_incidents` | `skills/sentinel/Get-SentinelIncident.ps1` | List Sentinel incidents | Azure auth context |
| `get_sentinel_alert_rules` | `skills/sentinel/Get-SentinelAlertRule.ps1` | List Sentinel alert rules | Azure auth context |
| `get_intune_devices` | `skills/intune/Get-IntuneDevice.ps1` | List Intune devices | Graph auth context |
| `get_intune_policies` | `skills/intune/Get-IntuneConfigurationPolicy.ps1` | List Intune config policies | Graph auth context |
| `get_teams_channels` | `skills/teams/Get-TeamsChannel.ps1` | List Teams channels | Graph auth context |
| `get_teams_members` | `skills/teams/Get-TeamsMember.ps1` | List Teams members | Graph auth context |
| `get_powerplatform_envs` | `skills/powerplatform/Get-PowerPlatformEnvironment.ps1` | List Power Platform environments | Power Platform auth context |
| `get_copilot_agent_info` | `skills/copilotstudio/Get-CopilotAgentInfo.ps1` | Get Copilot agent info | Dataverse auth context |
| `deploy_copilot_agent` | `skills/copilotstudio/Deploy-CopilotAgent.ps1` | Deploy/publish Copilot agent | Dataverse auth context |
| `manage_copilot_knowledge` | `skills/copilotstudio/Manage-CopilotKnowledge.ps1` | Manage Copilot knowledge sources | Dataverse auth context |
| `invoke_vm_run_command` | `skills/vm-guest-management/Invoke-VmRunCommand.ps1` | Execute command on Azure VM | Azure auth context |
| `connect_vm_bastion_ssh` | `skills/vm-guest-management/Connect-VmBastionSsh.ps1` | SSH via Azure Bastion | Azure auth context |

## Auth Pattern

### Step 1: Detect or Configure Auth

```powershell
# Option A: Auto-detect the best auth method for a resource
$authContext = ./prerequisites/Setup-AuthenticationContext.ps1 -Resource "https://management.azure.com/"

# Option B: Explicit auth with full control
$graphCtx = ./skills/graph/Connect-GraphApi.ps1 `
    -AuthenticationType ManagedIdentity `
    -Environment AzureCloud
```

### Step 2: Use the Context

```powershell
# Pass the context object to invocation scripts
./skills/graph/Invoke-GraphRequest.ps1 -Context $graphCtx -Uri "/users?`$select=id,displayName,mail"
```

### Step 3: Multi-Tenant Safety

```powershell
# Use prefixed environment variables for multiple tenants
$prod = ./skills/graph/Connect-GraphApi.ps1 -Prefix "PROD" -Environment AzureCloud
$gov  = ./skills/graph/Connect-GraphApi.ps1 -Prefix "GOV" -Environment AzureUSGovernment
```

## Security Boundaries

### Hard Rules

1. **No embedded secrets.** Never hardcode passwords, client secrets, or certificates in scripts.
2. **Auth hierarchy is enforced.** Managed Identity > Federated > Certificate > Client Secret. Using client secrets emits a mandatory runtime warning.
3. **No interactive auth.** Device code and browser login are not supported in skill execution.
4. **Context isolation.** Always pass explicit auth context objects. Never rely on global session state.

### Secret Management

- Use `-Prefix` parameter with environment variables: `PROD_TENANT_ID`, `PROD_CLIENT_ID`
- Use `-Profile` with `config.yaml` for centralized multi-tenant config
- For certificates, use secure paths and `SecureString` for passwords
- For Key Vault integration, see `docs/secret-management.md`

## Common Workflows

### Workflow: List Sentinel Incidents from Last 24 Hours

```powershell
# 1. Setup auth (auto-detect)
$ctx = ./prerequisites/Setup-AuthenticationContext.ps1 -Resource "https://management.azure.com/"

# 2. Get incidents
./skills/sentinel/Get-SentinelIncident.ps1 -AuthContext $ctx -WorkspaceName "my-workspace"
```

### Workflow: Run KQL Query Against Log Analytics

```powershell
# 1. Connect to Log Analytics
$laCtx = ./skills/loganalytics/Connect-LogAnalyticsApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

# 2. Run KQL
./skills/loganalytics/Invoke-LogAnalyticsKqlQuery.ps1 `
    -AuthContext $laCtx `
    -WorkspaceId "00000000-0000-0000-0000-000000000000" `
    -Query "SecurityAlert | where TimeGenerated > ago(24h) | take 10"
```

### Workflow: List Intune Devices with Compliance Status

```powershell
# 1. Connect to Graph (Intune uses Graph endpoints)
$graphCtx = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

# 2. Get devices
./skills/intune/Get-IntuneDevice.ps1 -AuthContext $graphCtx

# 3. Get configuration policies
./skills/intune/Get-IntuneConfigurationPolicy.ps1 -AuthContext $graphCtx
```

### Workflow: Query Dataverse Entities

```powershell
# 1. Connect to Dataverse
$dvCtx = ./skills/dataverse/Connect-DataverseApi.ps1 `
    -AuthenticationType ManagedIdentity `
    -EnvironmentUrl "https://contoso.crm.dynamics.com"

# 2. Query accounts
./skills/dataverse/Invoke-DataverseRequest.ps1 `
    -AuthContext $dvCtx `
    -Uri "/accounts?`$select=accountid,name&`$top=50"
```

## Error Handling

All scripts follow consistent error patterns:
- Validate required auth context fields before execution
- Throw on auth failures with descriptive messages
- Return structured output (arrays/hashtables) on success
- Emit warnings (not errors) for client secret usage

## Environment Support

- **AzureCloud** (Commercial)
- **AzureUSGovernment** (US Gov)
- **AzureChinaCloud** (China)

All `Connect-*` scripts accept `-Environment` parameter. Endpoint resolution is handled automatically.

## Prerequisites

Before using any skill:

```powershell
# Install required modules
./prerequisites/Install-RequiredModules.ps1

# Verify environment
./prerequisites/Test-Prerequisites.ps1

# (Optional) Load .env file
Import-Module ./skills/Common.psm1
Load-DotEnv -Path "./.env"
```

## MCP Server

This repository includes an MCP (Model Context Protocol) server for agent integration.

- **Location:** `mcp/`
- **Purpose:** Expose all Connect/Invoke tools as MCP tools for Claude Code, Codex, Cursor, and other MCP-compatible agents
- **Setup:** See `mcp/README.md`

## Contributing

When adding a new skill:
1. Follow the normalized auth parameter set defined in this contract
2. Use `Common.psm1` for auth context resolution, REST execution, and pagination
3. Emit the mandatory warning if client secret auth is used
4. Document service-specific caveats in `docs/patterns-and-caveats.md`
5. Update the tool inventory in this file

## Documentation Index

| Document | Purpose |
|----------|---------|
| `README.md` | Project overview and quickstart |
| `llms.txt` | Concise agent discovery context |
| `docs/auth-patterns.md` | Auth method selection guide |
| `docs/secret-management.md` | Secret hierarchy and handling rules |
| `docs/multi-tenant-auth.md` | Multi-context session management |
| `docs/patterns-and-caveats.md` | Operational lessons learned |
| `docs/environment-endpoints.md` | Cross-cloud endpoint mapping |
| `skills/*/SKILL.md` | Per-service patterns and examples |

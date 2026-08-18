# Microsoft Cloud API Skills - Agent Context

## Project Objective

This project provides a **modular package of reusable skills** for working with different Microsoft cloud service APIs. The goal is to generalize and abstract the connection patterns, authentication flows, and API interaction models observed across diverse Microsoft cloud automation scenarios into a cohesive, reusable toolkit.

**Core Principle**: No secret material is embedded in any skill. All skills require explicit secret management through the approved hierarchy, with clear prerequisites documented per skill.

---

## Scope and Service Coverage

| Service Domain | Status | Skill Doc |
|----------------|--------|-----------|
| **Microsoft Graph** | Covered | [skills/graph/SKILL.md](skills/graph/SKILL.md) |
| **Azure Resource Manager** | Covered | [skills/azure/SKILL.md](skills/azure/SKILL.md) |
| **Dataverse** | Covered | [skills/dataverse/SKILL.md](skills/dataverse/SKILL.md) |
| **Power Platform / BAP** | Covered | [skills/powerplatform/SKILL.md](skills/powerplatform/SKILL.md) |
| **Copilot Studio** | Covered | [skills/copilotstudio/SKILL.md](skills/copilotstudio/SKILL.md) |
| **Microsoft Sentinel** | Covered | [skills/sentinel/SKILL.md](skills/sentinel/SKILL.md) |
| **Log Analytics** | Covered | [skills/loganalytics/SKILL.md](skills/loganalytics/SKILL.md) |
| **Microsoft Teams** | Covered | [skills/teams/SKILL.md](skills/teams/SKILL.md) |
| **Intune / Endpoint Manager** | Covered | [skills/intune/SKILL.md](skills/intune/SKILL.md) |
| **VM Guest Management** | Covered | [skills/vm-guest-management/SKILL.md](skills/vm-guest-management/SKILL.md) |
| **SharePoint Online** | Gap | [agents.md#documented-gaps](#documented-gaps) |
| **Microsoft Purview** | Gap | [agents.md#documented-gaps](#documented-gaps) |
| **Microsoft Defender** | Gap | [agents.md#documented-gaps](#documented-gaps) |
| **Microsoft Fabric / Power BI** | Gap | [agents.md#documented-gaps](#documented-gaps) |
| **Azure DevOps** | Gap | [agents.md#documented-gaps](#documented-gaps) |
| **Exchange Online** | Gap | [agents.md#documented-gaps](#documented-gaps) |

---

## Modular Skill Architecture

Each skill is designed as an **independent, composable unit** following PowerShell module conventions (where applicable) or script-based wrappers:

```
.
├── skills/
│   ├── Common.psm1                       # Shared auth, REST, pagination, endpoint resolution
│   ├── graph/
│   │   ├── SKILL.md                      # Graph-specific patterns, toolchain, examples
│   │   ├── Connect-GraphApi.ps1
│   │   ├── Invoke-GraphRequest.ps1
│   │   └── auth/
│   ├── azure/
│   │   ├── SKILL.md                      # ARM-specific patterns, async ops, examples
│   │   ├── Connect-AzureApi.ps1
│   │   ├── Invoke-AzureRestMethod.ps1
│   │   └── auth/
│   ├── dataverse/
│   │   ├── SKILL.md                      # OData, GDS, file ops, examples
│   │   ├── Connect-DataverseApi.ps1
│   │   ├── Invoke-DataverseRequest.ps1
│   │   ├── Get-DataverseEnvironment.ps1
│   │   └── auth/
│   ├── powerplatform/
│   │   ├── SKILL.md                      # BAP API, ARM token, examples
│   │   ├── Connect-PowerPlatformApi.ps1
│   │   └── Get-PowerPlatformEnvironment.ps1
│   ├── copilotstudio/
│   │   ├── SKILL.md                      # Dataverse bot entity, knowledge sources, examples
│   │   ├── Deploy-CopilotAgent.ps1
│   │   ├── Get-CopilotAgentInfo.ps1
│   │   └── Manage-CopilotKnowledge.ps1
│   ├── sentinel/
│   │   ├── SKILL.md                      # ARM management plane, incidents, alert rules
│   │   ├── Invoke-SentinelArmRequest.ps1
│   │   ├── Get-SentinelIncident.ps1
│   │   └── Get-SentinelAlertRule.ps1
│   ├── loganalytics/
│   │   ├── SKILL.md                      # KQL, workspace lifecycle, DCE/DCR, ingestion fallback
│   │   ├── Connect-LogAnalyticsApi.ps1
│   │   ├── Invoke-LogAnalyticsKqlQuery.ps1
│   │   ├── New-LogAnalyticsWorkspace.ps1
│   │   ├── New-LogAnalyticsCustomTable.ps1
│   │   ├── New-LogAnalyticsIngestionPipeline.ps1
│   │   ├── Send-LogAnalyticsData.ps1
│   │   └── auth/
│   ├── teams/
│   │   ├── SKILL.md                      # Graph v1.0 patterns, examples
│   │   ├── Get-TeamsChannel.ps1
│   │   ├── Get-TeamsMember.ps1
│   │   └── Invoke-TeamsGraphRequest.ps1
│   ├── intune/
│   │   ├── SKILL.md                      # v1.0 vs beta, list-vs-get, examples
│   │   ├── Get-IntuneDevice.ps1
│   │   ├── Get-IntuneConfigurationPolicy.ps1
│   │   └── Invoke-IntuneGraphRequest.ps1
│   ├── vm-guest-management/
│   │   ├── SKILL.md                      # Run Command, Bastion, SSH patterns
│   │   ├── Invoke-VmRunCommand.ps1
│   │   ├── Connect-VmBastionSsh.ps1
│   │   ├── Invoke-VmSshKeyRotation.ps1
│   │   └── Configure-VmSshServer.ps1
│   ├── sharepoint-online/                # Gap — directory placeholder only
│   │   └── SKILL.md                      # SharePoint Online gap documentation
│   ├── powerplatform/                    # Covered
│   └── copilotstudio/                    # Covered
├── prerequisites/
│   ├── Setup-AuthenticationContext.ps1   # Guided auth method detection and setup
│   ├── Install-RequiredModules.ps1       # Az, Microsoft.Graph, etc.
│   └── Test-Prerequisites.ps1            # Verify environment readiness
├── docs/
│   ├── auth-patterns.md                  # Decision matrix for auth method selection
│   ├── environment-endpoints.md          # Commercial vs Gov vs China endpoint mapping
│   ├── secret-management.md              # Secret hierarchy and configuration guidance
│   ├── token-chaining.md                 # Cross-platform token chaining patterns and examples
│   ├── patterns-and-caveats.md           # Observed patterns, lessons learned, and edge cases
│   ├── multi-tenant-auth.md              # Multi-tenant and multi-context authentication guidance
│   ├── project-positioning.md            # Ecosystem positioning and unique value proposition
│   ├── competitive-landscape.md          # Competitor and alternative analysis
│   └── future-considerations.md          # Optional integration opportunities (not in scope)
├── .env.example                          # Environment variable template with multi-tenant prefixes
├── config.yaml                           # Example multi-tenant configuration file
├── README.md                             # Project overview, quickstart, file map
└── agents.md                             # This file — master index and design specification
```

---

## Authentication Hierarchy

All skills enforce this preference order. See [docs/auth-patterns.md](docs/auth-patterns.md) for the full decision matrix.

| Rank | Method | When to Use |
|------|--------|-------------|
| 1 | **Managed Identity** | Azure-hosted workloads (VM, Function App, App Service, Arc) |
| 2 | **Federated Credentials (OIDC)** | GitHub Actions, Azure DevOps, GitLab CI/CD |
| 3 | **Certificate-Based Auth** | Hybrid, on-prem, or sovereign cloud where MI/OIDC unavailable |
| 4 | **Client Secret** | **Last resort only** — emits a mandatory runtime warning |

Interactive authentication (device code flow, browser login) is **not permitted** for skill execution.

### Normalized Authentication Parameter Set

All `Connect-*` functions expose a consistent parameter set. See [docs/auth-patterns.md](docs/auth-patterns.md) for the full contract.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-AuthenticationType` | `string` | Yes | `ManagedIdentity`, `Federated`, `Certificate`, `ClientCredentials` |
| `-TenantId` | `string` | Conditional | Required for Federated, Certificate, ClientCredentials |
| `-ClientId` | `string` | Conditional | Required for Federated, Certificate, ClientCredentials |
| `-ClientSecret` | `SecureString` | Conditional | Required only for ClientCredentials |
| `-CertificatePath` | `string` | Conditional | Required for Certificate |
| `-CertificatePassword` | `SecureString` | Optional | Password for encrypted PFX |
| `-FederatedToken` | `string` | Conditional | OIDC token from CI/CD platform |
| `-UseManagedIdentity` | `switch` | No | Alias for `-AuthenticationType ManagedIdentity` |
| `-Environment` / `-AzureEnvironment` | `string` | Yes | `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud` |

---

## Multi-Tenant Authentication

Skills support multiple Entra ID tenants via:
- **Centralized config file**: `config.yaml` with named profiles + `-Profile` parameter
- **Prefixed environment variables**: `PROD_TENANT_ID`, `GOV_CLIENT_ID`, etc. + `-Prefix` parameter

See [docs/multi-tenant-auth.md](docs/multi-tenant-auth.md) for full guidance.

---

## Documented Gaps

These service domains are scoped but not yet implemented in this PowerShell toolkit. However, dedicated MCP servers now exist for each gap — see [`docs/future-considerations.md`](docs/future-considerations.md) for a comprehensive catalog.

| Service | Status | Notes |
|---------|--------|-------|
| **SharePoint Online** | Gap | Requires PnP PowerShell for data plane; Graph has partial coverage. See [skills/sharepoint-online/SKILL.md](skills/sharepoint-online/SKILL.md) |
| **Microsoft Purview** | Gap | Documented as future requirement. MCP servers: `microsoft/purview-dlm-mcp`, `str-mcp-purview`, `scardoso-lu/purview-mcp-server` |
| **Microsoft Defender** | Gap | Documented as future requirement. MCP servers: `MenkW/Defender-MCP`, `markolauren/ResponseMCP`. Defender for Cloud remains uncovered. |
| **Microsoft Fabric / Power BI** | Gap | Documented as future requirement. MCP servers: `microsoft/powerbi-modeling-mcp`, `enelyse/powerbi-mcp-server` |
| **Azure DevOps** | Gap | Documented as future requirement. MCP server: `microsoft/azure-devops-mcp` |
| **Exchange Online** | Gap | Documented as future requirement. MCP servers: `softeria/ms-365-mcp-server`, `DustHoff/msgraphmcp`, `dsswift/mcp-exchange` |

---

## Commands

```powershell
# Install prerequisites
./prerequisites/Install-RequiredModules.ps1

# Verify environment
./prerequisites/Test-Prerequisites.ps1

# Run smoke tests (no live auth required)
./prerequisites/Test-Smoke.ps1

# Run token validation tests (audience mismatches, expiry)
./prerequisites/Test-TokenValidation.ps1

# Load .env file (optional)
Import-Module ./skills/Common.psm1
Load-DotEnv -Path "./.env"

# Auto-detect authentication
$authContext = ./prerequisites/Setup-AuthenticationContext.ps1 -Resource "https://management.azure.com/"

# Example: Connect to Graph with explicit parameters
./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

# Example: Connect to Graph with a config profile
./skills/graph/Connect-GraphApi.ps1 -Profile "prod" -ConfigPath "./config.yaml"

# Example: Connect to Graph with prefixed environment variables
./skills/graph/Connect-GraphApi.ps1 -Prefix "GOV" -Environment AzureUSGovernment
```

---

## Standardized Context Object

All `Connect-*` scripts return a **plain hashtable** with these keys:

| Key | Type | Description |
|-----|------|-------------|
| `Token` | `string` | Bearer token for the target service audience |
| `ExpiresOn` | `datetime` | Token expiry in UTC |
| `TenantId` | `string` | Entra ID tenant GUID |
| `ClientId` | `string` | Application (client) ID |
| `Environment` | `string` | `AzureCloud`, `AzureUSGovernment`, or `AzureChinaCloud` |
| `BaseUri` | `string` | Service-specific base endpoint |
| `AuthenticationType` | `string` | Method used: `ManagedIdentity`, `Federated`, `Certificate`, `ClientCredentials` |

Service-specific additions:
- **Azure ARM**: `SubscriptionId`, `ArmEndpoint`
- **Dataverse**: `EnvironmentUrl`
- **Power Platform**: `BapEndpoint`

Downstream skill scripts accept this context via `-AuthContext` (or `-Context` for service-specific wrappers) and validate required fields before use.

---

## Stack

- **PowerShell** (primary skill language)
- **Python** (auxiliary scripts, certificate handling, token decoding)
- **Bicep / Azure CLI** (Azure deployment skills)

---

## Documentation Index

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Project overview, quickstart, file map |
| **Per-skill docs** | Domain-specific patterns, toolchain, examples |
| [docs/auth-patterns.md](docs/auth-patterns.md) | Auth method selection guide |
| [docs/secret-management.md](docs/secret-management.md) | Secret hierarchy and hard prohibitions |
| [docs/environment-endpoints.md](docs/environment-endpoints.md) | Cross-cloud endpoint mapping |
| [docs/token-chaining.md](docs/token-chaining.md) | Cross-service token reuse |
| [docs/multi-tenant-auth.md](docs/multi-tenant-auth.md) | Multi-context session management |
| [docs/patterns-and-caveats.md](docs/patterns-and-caveats.md) | Operational lessons learned |
| [docs/project-positioning.md](docs/project-positioning.md) | Ecosystem positioning |
| [docs/competitive-landscape.md](docs/competitive-landscape.md) | Alternative solutions |
| [docs/future-considerations.md](docs/future-considerations.md) | Integration opportunities |
| [docs/lsp-recommendations.md](docs/lsp-recommendations.md) | Language Server Protocol guidance for contributors |

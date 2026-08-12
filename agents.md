# Microsoft Cloud API Skills - Agent Context

## Project Objective

This project provides a **modular package of reusable skills** for working with different Microsoft cloud service APIs. The goal is to generalize and abstract the connection patterns, authentication flows, and API interaction models observed across diverse Microsoft cloud automation scenarios into a cohesive, reusable toolkit.

**Core Principle**: No secret material is embedded in any skill. All skills require explicit secret management through environment variables, Azure Key Vault, or managed identity, with clear prerequisites documented per skill.

---

## Scope and Service Coverage

| Service Domain | APIs | Key Patterns |
|----------------|------|--------------|
| **Microsoft Graph** | `graph.microsoft.com` (commercial), `graph.microsoft.us` (USGov), `graph.microsoft.cn` (China) | Device code, client credentials, certificate-based auth, delegated permissions, app-only tokens |
| **Azure Resource Manager** | `management.azure.com`, Bicep, Azure CLI | Service principal auth, managed identity, federated credentials (OIDC), ARM template deployment |
| **Dataverse / Power Platform** | `*.crm.dynamics.com`, BAP API (`api.bap.microsoft.com`) | OAuth2 client_credentials, environment discovery via Global Discovery Service, Web API OData |
| **Copilot Studio** | Dataverse-backed (bot/botcomponent entities), PAC CLI | Agent deployment, knowledge source management, privilege/role automation |
| **Azure Monitor / Log Analytics** | Data Collection Endpoint ingestion | Bearer token acquisition for `https://monitor.azure.com/` |

---

## Modular Skill Architecture

Each skill is designed as an **independent, composable unit** following PowerShell module conventions (where applicable) or script-based wrappers:

```
.
├── skills/
│   ├── graph/
│   │   ├── Connect-GraphApi.ps1          # Unified Graph connection with environment awareness
│   │   ├── Invoke-GraphRequest.ps1       # Request wrapper with pagination, caching, throttling
│   │   └── auth/
│   │       ├── DeviceCode.ps1
│   │       ├── ClientCredentials.ps1
│   │       ├── CertificateBased.ps1
│   │       └── ManagedIdentity.ps1
│   ├── azure/
│   │   ├── Connect-AzureApi.ps1          # Azure ARM / CLI context establishment
│   │   ├── Invoke-AzureRestMethod.ps1    # Generic Azure REST wrapper
│   │   └── auth/
│   │       ├── ServicePrincipal.ps1
│   │       ├── FederatedCredentials.ps1
│   │       └── ManagedIdentity.ps1
│   ├── dataverse/
│   │   ├── Connect-DataverseApi.ps1      # Dataverse Web API connection
│   │   ├── Invoke-DataverseRequest.ps1   # OData request wrapper
│   │   ├── Get-DataverseEnvironment.ps1  # Global Discovery Service lookup
│   │   └── auth/
│   │       └── ClientCredentials.ps1
│   ├── powerplatform/
│   │   ├── Connect-PowerPlatformApi.ps1  # BAP API connection
│   │   └── Get-PowerPlatformEnvironment.ps1
│   └── copilotstudio/
│       ├── Deploy-CopilotAgent.ps1       # PAC CLI or Dataverse-based deployment
│       ├── Get-CopilotAgentInfo.ps1      # Agent metadata via Dataverse
│       └── Manage-CopilotKnowledge.ps1   # Knowledge source CRUD
├── prerequisites/
│   ├── Install-RequiredModules.ps1       # Az, Microsoft.Graph, etc.
│   └── Test-Prerequisites.ps1            # Verify auth, permissions, endpoints
└── docs/
    ├── auth-patterns.md                  # Decision matrix for auth method selection
    ├── environment-endpoints.md          # Commercial vs Gov vs China endpoint mapping
    └── secret-management.md              # .env, Key Vault, managed identity guidance
```

---

## Authentication Patterns Summary

### 1. Device Code Flow (Interactive Setup)
- **Use Case**: Local development, initial tenant onboarding
- **Prerequisites**: User with sufficient privileges, browser access

### 2. Client Credentials (App-Only)
- **Use Case**: CI/CD pipelines, unattended automation, service-to-service
- **Prerequisites**: App registration, client secret or certificate, granted API permissions

### 3. Certificate-Based Auth
- **Use Case**: High-security environments, government cloud, secret rotation avoidance
- **Prerequisites**: X.509 certificate registered to app, private key access

### 4. Managed Identity (System / User Assigned)
- **Use Case**: Azure-hosted workloads (VM, Function App, Container Instance)
- **Prerequisites**: Azure resource with managed identity enabled, role assignments

### 5. Federated Credentials (OIDC)
- **Use Case**: GitHub Actions, Azure DevOps pipelines, short-lived token exchange
- **Prerequisites**: Federated identity credential configured on app registration

### 6. Cross-Tenant / Already Authenticated
- **Use Case**: Multi-tenant management, context switching, chained operations
- **Prerequisites**: Valid token from home tenant, managing tenant access

---

## Azure Multi-Tool Landscape and Token Chaining

Microsoft cloud APIs can be reached through multiple overlapping toolchains. Skills must be explicit about which layer they use and when to chain tools.

### Toolchain Comparison

| Tool | Best For | Token Audience | Limitations |
|------|----------|----------------|-------------|
| **Azure CLI** (`az`) | Cross-platform scripting, Bicep/ARM deployment, quick ad-hoc commands | `https://management.azure.com/` (ARM) by default; can request tokens for other audiences via `az account get-access-token --resource` | Not available in all execution contexts (e.g., restricted containers); output parsing can be brittle |
| **Az PowerShell modules** (`Az.Accounts`, `Az.Resources`, etc.) | Native PowerShell pipelines, object-oriented output, Azure Resource Graph | `https://management.azure.com/` (ARM) by default; `Get-AzAccessToken -ResourceTypeName MSGraph` yields Graph tokens | Heavy module dependency tree; version conflicts between `Az` and `Microsoft.Graph` modules can occur |
| **Microsoft.Graph PowerShell SDK** (`Microsoft.Graph.*`) | Rich Graph entity coverage, strong typing, pagination handled automatically | `https://graph.microsoft.com/` (or gov/china equivalent) | Large module footprint; some beta endpoints lag behind REST API; app-only vs delegated context can be confusing |
| **Raw REST (`Invoke-RestMethod`)** | Full control over headers, body, and URI; required for APIs without a dedicated SDK (e.g., Dataverse Web API, BAP API, Azure Monitor ingestion) | Any audience, provided you supply a valid `Authorization: Bearer <token>` header | Caller must handle pagination, throttling, retry logic, and token refresh manually |
| **PAC CLI** (`pac`) | Power Platform / Copilot Studio solution packaging, environment management, agent deployment | Power Platform admin scope; internally handles Dataverse token acquisition | Does not expose all Dataverse entity fields; limited to supported operations |
| **Bicep / ARM Templates** | Declarative Azure infrastructure; `what-if` validation; policy-driven compliance | ARM deployment identity (service principal or managed identity) | Imperative logic (loops, conditionals) is limited; no direct Graph or Dataverse integration |

### Token Chaining: Azure → Graph → Dataverse

A common and efficient pattern is to authenticate once to Azure (via Az module or Azure CLI), then use that context to acquire tokens for other Microsoft platforms without re-prompting for credentials.

**Example: Az → Graph**
```powershell
# 1. Authenticate to Azure (ARM)
Connect-AzAccount -TenantId $env:TENANT_ID -Subscription $env:SUBSCRIPTION_ID

# 2. Acquire a Microsoft Graph access token from the Azure context
$graphToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token

# 3. Pass the token to the Graph SDK
Connect-MgGraph -AccessToken ($graphToken | ConvertTo-SecureString -AsPlainText)
```

**Example: Azure CLI → Dataverse**
```bash
# 1. Log in to Azure
az login --service-principal -u $CLIENT_ID -p $CLIENT_SECRET --tenant $TENANT_ID

# 2. Request a token for the Dataverse environment audience
az account get-access-token --resource $DATAVERSE_ENVIRONMENT_URL --query accessToken -o tsv
```

**Key Nuances**
- **Audience mismatch is the most common failure**: `Get-AzAccessToken` without `-ResourceTypeName` returns an ARM token. Passing that to Graph or Dataverse will result in 401 Unauthorized.
- **Token lifetime**: chained tokens are short-lived (typically 1 hour). Long-running scripts must implement refresh logic or use the SDK's built-in token management.
- **Government cloud chaining**: When using `az account get-access-token` in USGov, ensure the CLI is logged into the correct cloud (`az cloud set --name AzureUSGovernment`) before requesting tokens; otherwise the token issuer will be wrong.
- **Managed identity chaining**: On Azure resources, `Get-AzAccessToken` and `az account get-access-token` both work with the VM's managed identity, making token chaining possible without any client secrets.

### When to Use Which Layer

- **Use Azure CLI or Az PowerShell** when the primary task is Azure resource management (deployments, policy, RBAC, network).
- **Use Microsoft.Graph SDK** when the primary task is directory, identity, or M365 data (users, groups, devices, conditional access).
- **Use raw REST** when the target API lacks a first-class SDK (Dataverse OData, BAP, Azure Monitor ingestion, custom endpoints).
- **Use PAC CLI** when the task is specifically Power Platform / Copilot Studio solution lifecycle management.
- **Chain tokens** when a single script must touch multiple platforms and you want to avoid multiple interactive sign-ins or redundant secret handling.

---

## Secret Management Requirements

All skills enforce the following secret handling rules:

1. **Never embed secrets in code**. All credentials are parameterized.
2. **Environment variables first**. Skills read from `$env:` / `Env:` with `.env` file support.
3. **Azure Key Vault optional**. Skills may accept a `KeyVaultName` parameter to retrieve secrets at runtime.
4. **Managed identity preferred on Azure**. When `UseManagedIdentity` is true, client secrets are ignored.
5. **Certificate paths only**. Private keys are never stored in the repository; only file paths are accepted.

**Required `.env` variables** (see `.env.example` for full template):
- `TENANT_ID`, `CLIENT_ID`, `CLIENT_SECRET` (or cert path)
- `AZURE_ENVIRONMENT` (`AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud`)
- `DATAVERSE_ENVIRONMENT_URL` (for Dataverse skills)
- `SUBSCRIPTION_ID` (for Azure ARM skills)

---

## Observed Patterns and Caveats

| Pattern Domain | Key Approach | Caveat / Lesson |
|----------------|--------------|-----------------|
| **Unified Connection Entry Point** | A single `Connect-*` function that branches by `AuthenticationType` (e.g., interactive, device code, managed identity, federated credentials, already-authenticated) reduces caller complexity and ensures consistent session state. | Cache directories and token stores must be explicitly managed per session; cross-tenant context switches require defensive cleanup (e.g., `try/finally` to restore original context). |
| **Token Pass-Through Between Platforms** | Authenticating to Azure first (Az.Accounts or Azure CLI) and then calling `Get-AzAccessToken -ResourceTypeName MSGraph` to retrieve a Graph bearer token avoids duplicate credential prompts and leverages a single sign-on context. | The token audience must match the target API exactly; passing a token scoped for `https://management.azure.com/` to Graph will fail. |
| **Dataverse Web API File Operations** | Uploading file content to Dataverse `filedata` columns should use `PATCH .../filedata`; chunked uploads require `InitializeFileBlocksUpload` → `UploadBlock` (repeated) → `CommitFileBlocksUpload`. | Using `.../filedata/$value` for uploads returns errors; that suffix is valid only for downloads. |
| **PAC CLI Limitations** | The Power Platform CLI (`pac`) is convenient for Copilot Studio agent import/export, but it does not always apply all manifest settings (e.g., descriptions, instructions) during deployment. | Fallback to Dataverse Web API direct updates or solution XML enhancement may be required when PAC CLI leaves settings incomplete. |
| **BAP API Permission Edge Cases** | The Business Applications Platform (BAP) API for environment enumeration and capacity checks may return 403 even when the caller holds the Dynamics 365 Service Administrator or Power Platform Admin role. | Tenant-level admin consent or explicit environment-level role assignment may be required; direct Dataverse Web API calls can sometimes bypass BAP restrictions. |
| **Government Cloud Endpoint Mapping** | Graph, ARM, Dataverse, and BAP endpoints all change in sovereign clouds (USGov, China, Germany). | Hard-coding `graph.microsoft.com` or `management.azure.com` will fail in non-commercial clouds; all skills must resolve endpoints dynamically based on an `-Environment` parameter. |
| **Dataverse Global Discovery Service** | Environment URLs can be discovered at runtime via the Global Discovery Service rather than hard-coding them. | The GDS base URL itself varies by cloud (e.g., `crm.dynamics.com` vs `crm9.dynamics.com` vs `crm.dynamics.cn`); discovery logic must be environment-aware. |
| **UI-Level Validation Gaps** | API-level validation of Copilot Studio agent permissions does not always reflect the actual end-user experience in the studio UI. | Browser automation (e.g., Playwright) may be required to validate that a user can actually open, edit, and publish an agent after API-level role assignments succeed. |
| **Modular Module Structure** | Separating concerns into `Classes/Models`, `Classes/Services`, and `Public/Private` folders makes PowerShell modules maintainable and testable. | This pattern applies to module architecture generally, not to cloud API auth logic specifically. |

---

## Endpoint Environment Mapping

| Cloud | Graph API | Azure ARM | Dataverse GDS | BAP API |
|-------|-----------|-----------|---------------|---------|
| **AzureCloud** (Commercial) | `https://graph.microsoft.com` | `https://management.azure.com` | `https://globaldisco.crm.dynamics.com` | `https://api.bap.microsoft.com` |
| **AzureUSGovernment** | `https://graph.microsoft.us` | `https://management.usgovcloudapi.net` | `https://globaldisco.crm9.dynamics.com` | `https://api.bap.microsoft.us` |
| **AzureChinaCloud** | `https://microsoftgraph.chinacloudapi.cn` | `https://management.chinacloudapi.cn` | `https://globaldisco.crm.dynamics.cn` | `https://api.bap.microsoft.cn` |

Skills must accept an `-Environment` or `-AzureEnvironment` parameter and resolve endpoints accordingly.

---

## Commands

```powershell
# Install prerequisites
./prerequisites/Install-RequiredModules.ps1

# Verify environment readiness
./prerequisites/Test-Prerequisites.ps1

# Example: Connect to Graph with device code
./skills/graph/Connect-GraphApi.ps1 -AuthenticationType DeviceCode -Environment AzureCloud

# Example: Connect to Dataverse with client credentials
./skills/dataverse/Connect-DataverseApi.ps1 -ClientId $env:CLIENT_ID -ClientSecret $env:CLIENT_SECRET -EnvironmentUrl $env:DATAVERSE_ENVIRONMENT_URL
```

---

## Stack

- **PowerShell** (primary skill language)
- **Python** (auxiliary scripts, certificate handling, token decoding)
- **Bicep / Azure CLI** (Azure deployment skills)

---

## LSP Configuration

```json
{
  "lsp": {
    "powershell": {
      "command": [
        "pwsh",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        "/home/azureuser/.local/share/PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1",
        "-HostName", "oh-my-openagent",
        "-HostProfileId", "0",
        "-HostVersion", "1.0.0",
        "-BundledModulesPath", "/home/azureuser/.local/share/PowerShellEditorServices",
        "-LogPath", "/tmp/powershell-es.log",
        "-LogLevel", "Normal",
        "-SessionDetailsPath", "/tmp/powershell-es.session",
        "-Stdio"
      ],
      "extensions": [".ps1", ".psm1", ".psd1"]
    }
  }
}
```

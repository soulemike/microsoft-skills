# Microsoft Cloud API Skills - Agent Context

## Project Objective

This project provides a **modular package of reusable skills** for working with different Microsoft cloud service APIs. The goal is to generalize and abstract the connection patterns, authentication flows, and API interaction models discovered across multiple real-world projects into a cohesive, reusable toolkit.

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
- **Projects**: aiAccelerate (SP creation), EntraOps (UserInteractive/DeviceAuthentication)
- **Prerequisites**: User with sufficient privileges, browser access

### 2. Client Credentials (App-Only)
- **Use Case**: CI/CD pipelines, unattended automation, service-to-service
- **Projects**: aiAccelerate (Dataverse/BAP), empire (Graph/Dataverse), jfBrennan (Graph USGov)
- **Prerequisites**: App registration, client secret or certificate, granted API permissions

### 3. Certificate-Based Auth
- **Use Case**: High-security environments, government cloud, secret rotation avoidance
- **Projects**: jfBrennan (USGov Intune), empire (Graph cert auth)
- **Prerequisites**: X.509 certificate registered to app, private key access

### 4. Managed Identity (System / User Assigned)
- **Use Case**: Azure-hosted workloads (VM, Function App, Container Instance)
- **Projects**: EntraOps (SystemAssignedMSI / UserAssignedMSI)
- **Prerequisites**: Azure resource with managed identity enabled, role assignments

### 5. Federated Credentials (OIDC)
- **Use Case**: GitHub Actions, Azure DevOps pipelines, short-lived token exchange
- **Projects**: EntraOps (GitHub workflows with `azure/login@v2`)
- **Prerequisites**: Federated identity credential configured on app registration

### 6. Cross-Tenant / Already Authenticated
- **Use Case**: Multi-tenant management, context switching, chained operations
- **Projects**: EntraOps (CrossTenantObjectResolution), maester (multi-environment)
- **Prerequisites**: Valid token from home tenant, managing tenant access

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

## Learnings from Reference Projects

| Project | Focus | Key Pattern | Caveat / Lesson |
|---------|-------|-------------|-----------------|
| **EntraOps** | Entra ID / Graph / Azure Resource Graph | Unified `Connect-EntraOps` with 6 auth modes; `Get-AzAccessToken` → `Connect-MgGraph` token pass-through | Cache directory must be explicitly managed; cross-tenant context requires finally-block restore |
| **aiAccelerate** | Copilot Studio / Dataverse / Azure OpenAI | Dataverse Web API with OAuth2 `client_credentials`; PAC CLI for agent deployment; knowledge file upload via `PATCH .../filedata` | File upload endpoint must be `.../filedata` not `.../filedata/$value`; PAC CLI may not apply all kickstart settings |
| **empire** | Copilot Studio governance / Dataverse RBAC | Cert-based Graph auth; BAP API for environment enumeration; Dataverse role/privilege automation via Web API | BAP API can return 403 even with Dynamics admin role in some tenants; Playwright needed for UI-level validation |
| **jfBrennan** | Azure Government / Intune / CMMC L2 | Graph USGov endpoints (`graph.microsoft.us`); certificate-based OAuth for device compliance evidence | Government cloud requires explicit endpoint mapping; standard commercial endpoints will fail |
| **maester** | Microsoft 365 assessment / security tests | `Connect-Maester` resolves Dataverse environment via Global Discovery Service; supports USGov/DoD/China | Dataverse GDS endpoint varies by cloud; Copilot Studio tests require Dataverse token in addition to Graph token |
| **anycloud** | Azure landing zone / CMMC L2 IaC | Azure CLI + Bicep deployment; `what-if` validation; Azure Policy compliance state | No Graph/Dataverse integration; purely ARM/Azure CLI |
| **PSHard** | On-prem Windows hardening / AD / GPO | Modular PowerShell module structure (`Classes/Services/Public/Private`) | No cloud API auth patterns; architecture pattern only |

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

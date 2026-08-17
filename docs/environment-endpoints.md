# Environment Endpoints

> **Purpose:** Centralize the cloud endpoint mappings that skills must resolve from the `-Environment` / `-AzureEnvironment` parameter.
>
> **Source:** Expanded from the endpoint mapping and toolchain guidance in `agents.md`.

---

## 1. Normalized Cloud Names

Every skill should treat the following names as the canonical environment identifiers:

- `AzureCloud`
- `AzureUSGovernment`
- `AzureChinaCloud`

These values drive endpoint selection, token audience selection, and cloud-specific operational behavior.

---

## 2. Core Cross-Cloud Endpoint Mapping

The project explicitly standardizes the following endpoints across supported clouds.

| Service / Purpose | AzureCloud | AzureUSGovernment | AzureChinaCloud |
|-------------------|------------|-------------------|-----------------|
| **Microsoft Graph API** | `https://graph.microsoft.com` | `https://graph.microsoft.us` | `https://microsoftgraph.chinacloudapi.cn` |
| **Azure Resource Manager (ARM)** | `https://management.azure.com` | `https://management.usgovcloudapi.net` | `https://management.chinacloudapi.cn` |
| **Login authority** | `https://login.microsoftonline.com` | `https://login.microsoftonline.us` | `https://login.chinacloudapi.cn` |
| **Dataverse Global Discovery Service** | `https://globaldisco.crm.dynamics.com` | `https://globaldisco.crm9.dynamics.com` | `https://globaldisco.crm.dynamics.cn` |
| **Dataverse environment URL pattern** | `https://*.crm.dynamics.com` | `https://*.crm9.dynamics.com` | `https://*.crm.dynamics.cn` |
| **Power Platform / BAP API** | `https://api.bap.microsoft.com` | `https://api.bap.microsoft.us` | `https://api.bap.microsoft.cn` |
| **Log Analytics query API (request endpoint)** | `https://api.loganalytics.azure.com` | `https://api.loganalytics.us` | `https://api.loganalytics.azure.cn` |
| **Log Analytics query API (token audience)** | `https://api.loganalytics.io/` | `https://api.loganalytics.us/` | `https://api.loganalytics.azure.cn/` |
| **Azure Monitor ingestion** | `https://monitor.azure.com` | Service-specific availability must be validated for sovereign cloud usage | Service-specific availability must be validated for sovereign cloud usage |
| **SharePoint Online host pattern** | `https://{tenant}.sharepoint.com` | `https://{tenant}.sharepoint.us` | `https://{tenant}.sharepoint.cn` |

---

## 3. Endpoint Usage by Service Domain

| Service Domain | Primary Endpoint / Audience | Notes |
|----------------|-----------------------------|-------|
| **Microsoft Graph** | Environment-specific Graph host above | Used for Graph, Teams, Intune, and some SharePoint-backed Graph operations |
| **Azure ARM** | Environment-specific ARM host above | Used for ARM, Bicep deployments, Azure control-plane operations, and Sentinel management plane |
| **Dataverse** | Environment-specific environment URL | The environment URL itself is the token audience for Web API calls |
| **Power Platform admin / BAP** | Environment-specific BAP API host above | Use for platform admin APIs and environment operations |
| **Sentinel management plane** | ARM endpoint for the selected cloud | Alert rules, watchlists, incidents, automation rules, and data connectors are ARM resources |
| **Sentinel / Log Analytics query plane** | `https://api.loganalytics.azure.com/` for REST requests | Token audience is `https://api.loganalytics.io/` (commercial). Use `Get-EnvironmentEndpoints` to resolve the correct audience per cloud. Do not use the request endpoint as the token resource. |
| **Azure Monitor ingestion** | `https://monitor.azure.com/` | Used for Data Collection Endpoint ingestion flows |
| **SharePoint Online** | Tenant-specific SharePoint host pattern above | SharePoint REST and CSOM require a SharePoint audience token rather than a Graph token |

---

## 4. Important Distinctions

### Graph vs. SharePoint Audience

A Graph token is not a universal M365 token. `agents.md` calls out a specific SharePoint caveat: SharePoint REST and CSOM require a **SharePoint audience token**, not a Graph token.

### ARM vs. Data Plane

Sentinel and Monitor span multiple planes:

- **Management plane** operations use the ARM endpoint.
- **Data plane** operations use Log Analytics or Monitor-specific endpoints.

Do not assume the control-plane token can be replayed directly against data-plane APIs.

### Log Analytics Token Audience vs. Request Endpoint

A common integration failure is using the Log Analytics request endpoint (`https://api.loganalytics.azure.com/`) as the token resource audience. This causes **AADSTS500011 (invalid_resource)** when acquiring tokens via managed identity or service principal.

The correct token audience for Log Analytics data-plane APIs is:

| Cloud | Token Audience | Request Endpoint |
|-------|---------------|------------------|
| AzureCloud | `https://api.loganalytics.io/` | `https://api.loganalytics.azure.com/` |
| AzureUSGovernment | `https://api.loganalytics.us/` | `https://api.loganalytics.us/` |
| AzureChinaCloud | `https://api.loganalytics.azure.cn/` | `https://api.loganalytics.azure.cn/` |

> **Rule:** Always use `LogAnalyticsTokenAudience` from `Get-EnvironmentEndpoints` for token acquisition, and `LogAnalytics` for the request URI.

### Dataverse Audience Rule

Dataverse does not use a single global API host for ordinary environment work. The environment URL itself is the resource audience, for example:

- Commercial: `https://contoso.crm.dynamics.com`
- US Gov: `https://contoso.crm9.dynamics.com`
- China: `https://contoso.crm.dynamics.cn`

Use Global Discovery only to locate the environment, then request a token for the environment URL you will call.

---

## 5. Cloud-Specific Notes

### AzureCloud

This is the default path for examples in the toolkit and the simplest environment for CLI and SDK parity.

### AzureUSGovernment

Use the government-specific Graph, ARM, Dataverse discovery, and BAP endpoints. Also expect tighter service parity checks because some tooling and preview features lag in sovereign clouds.

### AzureChinaCloud

China requires distinct Graph, ARM, Dataverse discovery, and BAP hosts. Do not rely on commercial defaults or host suffix assumptions.

---

## 6. Implementation Rule for Skills

Every `Connect-*` function should resolve endpoints from the selected cloud once, then carry those resolved values in the returned context object so downstream request functions do not guess.

Related docs:

- `docs/auth-patterns.md`
- `docs/token-chaining.md`

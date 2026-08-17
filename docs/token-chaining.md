# Token Chaining

> **Purpose:** Document the cross-platform token chaining patterns called out in `agents.md`, with examples and warnings for audience selection, cloud selection, and multi-service flows.

---

## 1. What Token Chaining Means Here

Token chaining is the act of reusing one authenticated runtime context to obtain access tokens for multiple Microsoft service audiences without creating separate credential stores for each service.

Typical examples in this project:

- **Azure context → Graph token**
- **Azure CLI context → Dataverse token**
- **Managed identity → any supported audience**

This reduces duplicate sign-in steps, but it does **not** mean one token can be replayed everywhere.

---

## 2. Core Rules

1. **Always request a token for the target audience.**
2. **Do not assume ARM, Graph, Dataverse, SharePoint, and Monitor share a token.**
3. **Expect short token lifetimes** and refresh accordingly.
4. **Carry the cloud context with the token context** so Commercial, Gov, and China do not get mixed.
5. **Prefer explicit context objects** when multiple tenants or environments are active.

---

## 3. Common Patterns

| Pattern | Tools Involved | Best Use Case | Main Warning |
|---------|----------------|---------------|--------------|
| **Azure → Graph** | `Az.Accounts` → Graph SDK or raw REST | Reuse Azure auth to call Graph without another login | Audience mismatch is the most common failure |
| **Azure CLI → Dataverse** | `az` → raw REST | Use an existing Azure CLI context to get a Dataverse token | Correct cloud must already be selected in Azure CLI |
| **Managed Identity → Any** | Managed identity + SDK / REST / CLI | Azure-hosted automation reaching multiple APIs | Only works where managed identity is actually available |

---

## 4. Azure → Graph Example

### PowerShell

```powershell
# Existing Azure context
$graphToken = Get-AzAccessToken -ResourceTypeName MSGraph

$headers = @{
    Authorization = "Bearer $($graphToken.Token)"
}

Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users" -Headers $headers
```

### Why this works

The Azure context is reused only to **obtain** a Graph token. The actual token presented to Graph still targets the Graph audience.

### Common failure

Calling Graph with an ARM token. The login succeeded, but the token audience is wrong.

---

## 5. Azure CLI → Dataverse Example

### Bash

```bash
DATAVERSE_URL="https://contoso.crm.dynamics.com"
ACCESS_TOKEN=$(az account get-access-token --resource "$DATAVERSE_URL" --query accessToken -o tsv)

curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  "$DATAVERSE_URL/api/data/v9.2/accounts?$top=5"
```

### Key point

Dataverse uses the **environment URL itself** as the audience. Reusing a Graph token or ARM token will fail.

---

## 6. Azure → Graph → Dataverse Example

This is the practical pattern when a single automation run spans identity objects, Azure resources, and Dataverse-backed workloads.

### PowerShell

```powershell
$armToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
$graphToken = Get-AzAccessToken -ResourceTypeName MSGraph
$dataverseUrl = 'https://contoso.crm.dynamics.com'
$dataverseToken = Get-AzAccessToken -ResourceUrl $dataverseUrl

Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups' -Headers @{
    Authorization = "Bearer $($graphToken.Token)"
}

Invoke-RestMethod -Uri "$dataverseUrl/api/data/v9.2/accounts?$top=5" -Headers @{
    Authorization = "Bearer $($dataverseToken.Token)"
    Accept = 'application/json'
}
```

### Why this matters

The automation reuses one authenticated runtime, but it still requests **three different tokens** because the audiences differ.

---

## 7. Audience Mismatch Warnings

These are the mistakes the toolkit should assume will happen unless documented clearly:

| Wrong Assumption | Why it fails |
|------------------|--------------|
| “A Graph token can call SharePoint REST.” | SharePoint REST requires a SharePoint audience token |
| “An ARM token can query Graph.” | Graph expects the Graph audience, not ARM |
| “A Dataverse token can manage Sentinel.” | Sentinel management uses ARM |
| “One token works across every Microsoft endpoint in a workflow.” | Each API validates its own audience |

When debugging, inspect the target URI first, then confirm the token audience matches it.

---

## 8. Government and Sovereign Cloud Considerations

Token chaining must follow the selected environment.

- **AzureUSGovernment**: use government-specific Graph and ARM endpoints and ensure the CLI / SDK context is targeting the gov cloud.
- **AzureChinaCloud**: use China-specific Graph and ARM endpoints and never rely on commercial defaults.
- **Dataverse and BAP**: the environment-specific discovery and API hosts also change by cloud.

The easiest failure mode in sovereign clouds is not authentication itself, but mixing the right identity with the wrong cloud endpoint.

---

## 9. Session Handling Guidance

When multiple tenants or clouds are active, keep separate context objects and pass them explicitly:

```powershell
$prodContext = Connect-GraphApi -Profile 'prod' -ConfigPath './config.yaml'
$govContext  = Connect-GraphApi -Prefix 'GOV'

Invoke-GraphRequest -Context $prodContext -Uri '/users'
Invoke-GraphRequest -Context $govContext -Uri '/users'
```

This prevents token reuse across the wrong tenant or cloud.

Related docs:

- `docs/environment-endpoints.md`
- `docs/multi-tenant-auth.md`

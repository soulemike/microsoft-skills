# Asset Tracking

> **Purpose:** Define standardized scaffolding for users to track and manage cloud assets created or interacted with through Microsoft Cloud API Skills.
>
> **Core principle:** Every resource operation should be traceable — know what you created, how you authenticated, and where to find it again.

---

## Why Asset Tracking Matters

When you use this toolkit to create Azure resources, query Graph objects, or manage Sentinel incidents, you need a consistent way to:

- **Remember what exists** — resource IDs, workspace names, environment URLs
- **Know how to reconnect** — which tenant, which auth method, which endpoint
- **Ensure consistency** — use the same auth context and protocol for the same asset over time
- **Share context safely** — asset inventories live outside version control

Without tracking, you end up with:
- Hardcoded resource IDs scattered across scripts
- Mismatched auth contexts across operations
- No audit trail of what was created when and by which skill

---

## Quickstart

### 1. Import the Asset Inventory Module

```powershell
Import-Module ./skills/Common.psm1
```

### 2. Register an Asset

After creating or discovering a resource, register it:

```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

# Create a resource
$rg = ./skills/azure/Invoke-AzureRestMethod.ps1 `
    -Uri "/subscriptions/$($ctx.SubscriptionId)/resourcegroups/my-rg" `
    -Method PUT -ApiVersion '2021-04-01' `
    -Body @{ location = 'eastus' } `
    -AuthContext $ctx

# Register it in your asset inventory
Add-AssetToInventory `
    -Id "/subscriptions/$($ctx.SubscriptionId)/resourcegroups/my-rg" `
    -Type "Microsoft.Resources/resourceGroups" `
    -Name "my-rg" `
    -Domain "azure" `
    -Endpoint "https://management.azure.com" `
    -AuthContextRef $ctx `
    -Properties @{ location = 'eastus' } `
    -Tags @{ environment = 'production'; costCenter = '12345' } `
    -ManagedBy "./skills/azure/Invoke-AzureRestMethod.ps1"
```

### 3. Look Up Assets

```powershell
# Find all production Azure assets
Get-AssetFromInventory -Domain "azure" -Tags @{ environment = "production" }

# Find a specific workspace
Get-AssetFromInventory -Name "my-workspace"

# Find all assets managed by a specific skill
Get-AssetFromInventory | Where-Object { $_.managedBy -like "*sentinel*" }
```

### 4. Update an Asset

```powershell
Update-AssetInInventory `
    -Id "/subscriptions/.../resourcegroups/my-rg" `
    -Tags @{ owner = "platform-team"; reviewed = "2026-09-25" }
```

### 5. Validate Your Inventory

```powershell
Test-AssetInventory
```

---

## Asset Inventory Schema

Asset inventories are stored as YAML in `./assets/` (gitignored by default).

### File Structure

```yaml
---
apiVersion: v1
kind: AssetInventory
metadata:
  name: my-tenant-assets
  tenantId: "00000000-0000-0000-0000-000000000000"
  environment: AzureCloud
  lastUpdated: "2026-09-25T12:00:00Z"
spec:
  assets:
    - id: "/subscriptions/.../resourceGroups/..."
      type: Microsoft.Resources/resourceGroups
      name: my-resource-group
      domain: azure
      protocol: https
      endpoint: https://management.azure.com
      authContextRef:
        tenantId: "00000000-0000-0000-0000-000000000000"
        environment: AzureCloud
        authenticationType: ManagedIdentity
        clientId: "00000000-0000-0000-0000-000000000000"
      properties:
        location: eastus
      tags:
        environment: production
      managedBy: ./skills/azure/Invoke-AzureRestMethod.ps1
      createdAt: "2026-09-25T12:00:00Z"
      updatedAt: "2026-09-25T12:00:00Z"
```

### Field Reference

| Field | Required | Description |
|---|---|---|
| `id` | Yes | Canonical resource identifier (ARM ID, Graph object ID, URL) |
| `type` | Yes | Resource type (ARM resource type, Graph entity type) |
| `name` | Yes | Human-readable name |
| `domain` | Yes | Service domain: `azure`, `graph`, `dataverse`, `sentinel`, `loganalytics`, `teams`, `intune`, `powerplatform`, `copilotstudio`, `vm-guest-management` |
| `protocol` | No | Communication protocol, defaults to `https` |
| `endpoint` | No | Base endpoint used to reach the resource |
| `authContextRef` | No | Snapshot of the auth context (tenant, environment, auth type, client ID) used when the asset was registered |
| `properties` | No | Service-specific properties (location, sku, region, etc.) |
| `tags` | No | User-defined tags for filtering and organization |
| `managedBy` | No | Path to the skill script that created or manages this asset |
| `createdAt` | Auto | ISO 8601 timestamp of registration |
| `updatedAt` | Auto | ISO 8601 timestamp of last modification |

---

## Per-Domain Asset Patterns

### Azure ARM Assets

```yaml
- id: "/subscriptions/{subscriptionId}/resourceGroups/{name}"
  type: Microsoft.Resources/resourceGroups
  name: {name}
  domain: azure
  endpoint: https://management.azure.com
```

### Log Analytics Workspaces

```yaml
- id: "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}"
  type: Microsoft.OperationalInsights/workspaces
  name: {name}
  domain: loganalytics
  endpoint: https://management.azure.com
  properties:
    customerId: "..."
    sku: PerGB2018
```

### Microsoft Graph Objects

```yaml
- id: "{objectId}"
  type: microsoft.graph.user
  name: "user@contoso.com"
  domain: graph
  endpoint: https://graph.microsoft.com
```

### Sentinel Incidents

```yaml
- id: "/subscriptions/{sub}/.../workspaces/{ws}/providers/Microsoft.SecurityInsights/Incidents/{id}"
  type: Microsoft.SecurityInsights/Incidents
  name: "Incident Title"
  domain: sentinel
  endpoint: https://management.azure.com
  properties:
    severity: High
    status: Active
```

### Dataverse Environments

```yaml
- id: "https://{org}.crm.dynamics.com"
  type: Microsoft.Dynamics.CRM.environment
  name: {org}
  domain: dataverse
  endpoint: https://{org}.crm.dynamics.com
```

---

## Multi-Environment Asset Tracking

Use separate inventories for separate environments to avoid context bleed:

```powershell
# Production assets
Add-AssetToInventory -InventoryName "prod-inventory" -Id "..." -Domain "azure"

# Development assets
Add-AssetToInventory -InventoryName "dev-inventory" -Id "..." -Domain "azure"

# Query production only
Get-AssetFromInventory -InventoryName "prod-inventory" -Domain "azure"
```

---

## Security and Git Hygiene

- The `assets/` directory is **gitignored** by default. Only `*.example.yaml` files are tracked.
- Never commit real `tenantId`, `subscriptionId`, or resource IDs to version control.
- `authContextRef` stores only non-secret identifiers (tenantId, environment, auth type). It does **not** store tokens or secrets.
- Asset inventories are user-managed files, not project source code.

---

## Integration with Skills

Skills can optionally register assets when they create or discover resources. Use the `-RegisterAsset` pattern:

```powershell
# Example: a skill that creates a workspace and registers it
param(
    [switch]$RegisterAsset,
    [string]$InventoryName = 'inventory'
)

# ... create workspace ...

if ($RegisterAsset) {
    Add-AssetToInventory `
        -Id $workspace.id `
        -Type $workspace.type `
        -Name $workspace.name `
        -Domain "loganalytics" `
        -AuthContextRef $AuthContext `
        -Properties @{ location = $Location; sku = $Sku } `
        -ManagedBy $PSCommandPath `
        -InventoryName $InventoryName
}
```

---

## PowerShell Functions Reference

| Function | Purpose |
|---|---|
| `Get-AssetInventory` | Load the full inventory hashtable |
| `Get-AssetInventoryPath` | Resolve the path to an inventory file |
| `Add-AssetToInventory` | Register a new asset |
| `Get-AssetFromInventory` | Query assets by ID, name, domain, or tags |
| `Update-AssetInInventory` | Modify properties or tags of an existing asset |
| `Remove-AssetFromInventory` | Delete an asset from the inventory |
| `Test-AssetInventory` | Validate inventory structure and required fields |
| `Save-AssetInventory` | Persist inventory to YAML |

---

## Related Documents

- [`docs/secret-management.md`](secret-management.md) — Secret handling rules
- [`docs/multi-tenant-auth.md`](multi-tenant-auth.md) — Multi-context session management
- [`assets/inventory.example.yaml`](../assets/inventory.example.yaml) — Example inventory template

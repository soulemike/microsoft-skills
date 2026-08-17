# Patterns and Caveats

> **Purpose:** Capture the recurring operational lessons and edge cases called out in `agents.md` so implementers do not rediscover them the hard way.

---

## 1. Intune: List vs. Get Is Not Symmetric

The Intune Graph surface often returns **incomplete collection payloads**.

### Managed devices

List calls such as `/deviceManagement/managedDevices` may return default, empty, or null values for fields that operators usually care about.

Examples from the spec include:

- `activationLockBypassCode`
- `hardwareInformation`
- `notes`
- `iccid`
- `udid`
- `ethernetMacAddress`
- `physicalMemoryInBytes`
- `remoteAssistanceSessionUrl`

**Recommended pattern:**

1. List objects to get IDs and lightweight metadata.
2. Follow up with per-item `GET` calls and a focused `$select`.

For policies, the pattern changes: the list usually gives the policy object, but the operational detail lives in child collections such as `/settings` or `/assignments`.

**Lesson:** `$expand` is not a universal fix. Use per-item `GET` for sparse device objects and child endpoints for policy detail.

---

## 2. VM Run Command: “Succeeded” Can Still Mean Failure

`agents.md` calls out a critical guest-management trap: a successful ARM or command status does **not** guarantee the guest script actually worked.

Always inspect:

- `instanceView.executionState`
- `instanceView.exitCode`
- `instanceView.output`
- `instanceView.error`

If available, prefer managed Run Command with `treatFailureAsDeploymentFailure=true` and blob output capture.

**Lesson:** provisioning success is a control-plane result, not proof of guest success.

---

## 3. SharePoint Online: Data Plane and Management Plane Are Different Worlds

SharePoint Online is not a single API surface.

### Data plane examples

- PnP PowerShell
- Graph SharePoint endpoints
- SharePoint REST API
- CSOM

### Management plane examples

- SharePoint Online Management Shell
- PnP tenant cmdlets
- Graph `/admin/sharepoint/settings`

The spec explicitly notes that Graph has only **partial coverage**. Site provisioning and tenant administration often require PnP or SPO Management Shell rather than Graph.

It also warns that SharePoint REST and CSOM require a **SharePoint audience token**, not a Graph token.

**Lesson:** first decide whether the task is content/data access or tenant administration, then choose tooling and token audience accordingly.

---

## 4. Graph Pagination Must Be a First-Class Behavior

Raw Graph REST usage requires explicit handling for:

- `@odata.nextLink`
- throttling via `Retry-After`
- token refresh

This matters across Graph-heavy services such as:

- Microsoft Graph directory operations
- Teams endpoints
- Intune list operations

**Lesson:** never treat a single page as a complete dataset unless the API contract explicitly says so.

---

## 5. Dataverse File Operations Need Their Own Handling Path

The Dataverse guidance in `agents.md` notes that raw REST is the right tool when the workflow requires:

- custom OData queries
- entity-specific operations
- **file uploads and downloads**

That matters because file operations are not just “normal JSON CRUD with a bigger payload.” They usually need dedicated request construction, explicit environment URL targeting, and more careful retry / paging behavior around the surrounding workflow.

**Lesson:** treat Dataverse file operations as a specialized request path, not as a trivial extension of standard table CRUD.

---

## 6. Summary Rules

- Intune collection responses often need enrichment.
- VM Run Command needs guest-level validation, not just ARM-level validation.
- SharePoint requires a data-plane vs. management-plane decision up front.
- Graph pagination and throttling handling are not optional.
- Dataverse file workflows deserve dedicated wrapper logic.

Related docs:

- `docs/token-chaining.md`
- `docs/environment-endpoints.md`

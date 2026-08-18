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

## 2. Az + Graph Module DLL Conflicts Are Predictable and Mitigable

Loading `Az.Accounts` and `Microsoft.Graph.Authentication` in the same PowerShell session frequently causes assembly load failures because both bundle different versions of `Microsoft.Identity.Client` and related identity DLLs.

This is not a transient bug — it is a structural consequence of how PowerShell 7 loads assemblies into a single default `AssemblyLoadContext`. The first module to load its version of a shared DLL "wins," and the second module may throw `MissingMethodException` or "Assembly with same name is already loaded."

### Mitigation

1. **Install DllPickle** (optional but recommended):
   ```powershell
   Install-Module DLLPickle -Scope CurrentUser
   ```
   DllPickle, by Sam Erde ([GitHub](https://github.com/SamErde/DLLPickle)), preloads a curated compatible identity assembly set before service modules load. This project aligns with DllPickle's preload / block classification and runtime reasoning.

2. **Use the conflict-safe loader** provided by this toolkit:
   ```powershell
   ./prerequisites/Import-ConflictSafeModules.ps1
   ```
   This helper invokes `Import-DPLibrary` if DllPickle is present, otherwise falls back to a manual load-order heuristic (MSAL.PS → Graph → Az).

3. **Check prerequisites** for conflict risk:
   ```powershell
   ./prerequisites/Test-Prerequisites.ps1 -Detailed
   ```

Full details and attribution: [`docs/dll-conflict-mitigation.md`](dll-conflict-mitigation.md)

**Lesson:** do not treat Az + Graph coexistence as safe by default. Preload or order your imports deliberately.

---
## 3. VM Run Command: “Succeeded” Can Still Mean Failure

`agents.md` calls out a critical guest-management trap: a successful ARM or command status does **not** guarantee the guest script actually worked.

Always inspect:

- `instanceView.executionState`
- `instanceView.exitCode`
- `instanceView.output`
- `instanceView.error`

If available, prefer managed Run Command with `treatFailureAsDeploymentFailure=true` and blob output capture.

**Lesson:** provisioning success is a control-plane result, not proof of guest success.

---

## 4. SharePoint Online: Data Plane and Management Plane Are Different Worlds

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

## 5. Graph Pagination Must Be a First-Class Behavior

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

## 6. Dataverse File Operations Need Their Own Handling Path

The Dataverse guidance in `agents.md` notes that raw REST is the right tool when the workflow requires:

- custom OData queries
- entity-specific operations
- **file uploads and downloads**

That matters because file operations are not just “normal JSON CRUD with a bigger payload.” They usually need dedicated request construction, explicit environment URL targeting, and more careful retry / paging behavior around the surrounding workflow.

**Lesson:** treat Dataverse file operations as a specialized request path, not as a trivial extension of standard table CRUD.

---

## 7. VM SSH Server Hardening: Azure-Mediated vs. Guest-Direct

The `vm-guest-management` skillset provides two distinct SSH access models that are often confused:

| Model | Mechanism | Use Case |
|-------|-----------|----------|
| **Azure-mediated** | Bastion tunnel, `az vm user update`, VMAccessForLinux extension | Azure-native access without exposing port 22 |
| **Guest-direct** | Native SSH daemon on VM, public IP + NSG rule | Direct automation, SCP/SFTP, third-party tooling |

### Research findings from related projects

Analysis of `~/projects/anycloud`, `~/projects/harness`, and `~/projects/aiAccelerate` revealed consistent Azure-side patterns but a gap in guest-side hardening:

**What exists (Azure-side provisioning):**
- `linuxConfiguration.disablePasswordAuthentication: true` in ARM/Bicep templates
- `ssh.publicKeys[].path: '/home/${adminUsername}/.ssh/authorized_keys'`
- NSG `AllowSSH` inbound rule on TCP/22 with source IP restriction
- Deployment helpers that auto-discover local `~/.ssh/id_rsa.pub`

**What was missing across all three projects:**
- No `sshd_config` template or drop-in configuration
- No explicit `PermitRootLogin no`, `AllowUsers`, `MaxAuthTries`
- No host key rotation logic
- No SSH CA (`TrustedUserCAKeys`) support
- No validation that `sshd -t` passes before restart

### Anti-pattern to avoid

Some automation scripts use `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` for ephemeral validation. This is acceptable only for one-time deployment smoke tests. Do not document or default to this for operational SSH access.

### Recommended hardening baseline

When enabling guest-direct SSH, apply a `sshd_config.d` drop-in:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
X11Forwarding no
PermitTunnel no
```

Optionally restrict with `AllowUsers` or `AllowGroups`. Always run `sshd -t` before `systemctl restart sshd`.

**Lesson:** Azure VM provisioning handles key injection and NSG rules, but guest OS sshd hardening is a separate responsibility. Treat them as complementary layers, not alternatives.

---

## 8. Summary Rules

- Intune collection responses often need enrichment.
- Az + Graph module DLL conflicts require deliberate preload or load-order management.
- VM Run Command needs guest-level validation, not just ARM-level validation.
- SharePoint requires a data-plane vs. management-plane decision up front.
- Graph pagination and throttling handling are not optional.
- Dataverse file workflows deserve dedicated wrapper logic.
- Azure-mediated SSH (Bastion, VMAccess) and guest-direct SSH (sshd) are different capabilities; hardening is required for the latter.

Related docs:

- `docs/token-chaining.md`
- `docs/environment-endpoints.md`
- `skills/vm-guest-management/SKILL.md`

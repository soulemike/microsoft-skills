# VM Guest Management Skill

## Overview
Provides reusable PowerShell wrappers for executing guest scripts on Azure VMs/Arc-enabled machines (Run Command) and for managing SSH access via Bastion and SSH key rotation.

## Authentication
- ARM token for Run Command and SSH key management
- Entra ID + Virtual Machine Administrator Login role for Bastion

## Endpoints
Uses ARM endpoint from environment.

## Skills
| File | Purpose |
|---------|---------|
| Invoke-VmRunCommand.ps1 | Invokes guest scripts via Azure VM Run Command (POST action) or managed Run Command resources (PUT), with instance-level result inspection and optional blob streaming. |
| Connect-VmBastionSsh.ps1 | Opens Azure Bastion SSH/RDP connections or starts a Bastion tunnel for local SSH/SCP/SFTP/IDE workflows using the Azure CLI. |
| Invoke-VmSshKeyRotation.ps1 | Rotates/injects VM SSH public keys using append-only guest execution or (for replacement) VMAccessForLinux extension, including optional temporary break-glass users. |
| Configure-VmSshServer.ps1 | Hardens the OpenSSH server on Azure Linux VMs using Run Command: sshd_config drop-in, password/root disablement, user/group restrictions, host key rotation, SSH CA configuration, and reachability verification. Enables native direct SSH without Azure Bastion proxying. |

## Toolchain
| Tool | Best For | Token Audience | Limitations |
|------|----------|----------------|-------------|
| **Azure CLI** (`az`) | Cross-platform scripting, Bicep/ARM deployment, quick ad-hoc commands | `https://management.azure.com/` (ARM) by default; can request tokens for other audiences via `az account get-access-token --resource` | Not available in all execution contexts (e.g., restricted containers); output parsing can be brittle |
| **Az PowerShell modules** (`Az.Accounts`, `Az.Resources`, etc.) | Native PowerShell pipelines, object-oriented output, Azure Resource Graph | `https://management.azure.com/` (ARM) by default; `Get-AzAccessToken -ResourceTypeName MSGraph` yields Graph tokens | Heavy module dependency tree; version conflicts between `Az` and `Microsoft.Graph` modules can occur |
| **Microsoft.Graph PowerShell SDK** (`Microsoft.Graph.*`) | Rich Graph entity coverage, strong typing, pagination handled automatically | `https://graph.microsoft.com/` (or gov/china equivalent) | Large module footprint; some beta endpoints lag behind REST API; app-only vs delegated context can be confusing |
| **Raw REST (`Invoke-RestMethod`)** | Full control over headers, body, and URI; required for APIs without a dedicated SDK (e.g., Dataverse Web API, BAP API, Azure Monitor ingestion) | Any audience, provided you supply a valid `Authorization: Bearer <token>` header | Caller must handle pagination, throttling, retry logic, and token refresh manually |
| **PAC CLI** (`pac`) | Power Platform / Copilot Studio solution packaging, environment management, agent deployment | Power Platform admin scope; internally handles Dataverse token acquisition | Does not expose all Dataverse entity fields; limited to supported operations |
| **Bicep / ARM Templates** | Declarative Azure infrastructure; `what-if` validation; policy-driven compliance | ARM deployment identity (service principal or managed identity) | Imperative logic (loops, conditionals) is limited; no direct Graph or Dataverse integration |

## Patterns & Caveats
### Action Run Command Limits
| Limit / Behavior | Value |
|---|---|
| Guest timeout parameter | `-TimeoutInSeconds` is validated as `1..5400` |
| Default timeout | `1800` seconds |
| Poll interval while waiting for completion | `5` seconds |
| Deadline calculation for waiting (Action Run Command) | `(Get-Date).AddSeconds($TimeoutInSeconds + 120)` |

### Managed Run Command (Production)
- Up to 25 per VM
- Supports timeoutInSeconds, runAsUser, outputBlobUri, errorBlobUri
- treatFailureAsDeploymentFailure

### Critical: Success Is Misleading
Provisioning success != guest script success. Always inspect instanceView.

### Multi-VM Execution
- Anti-pattern: unthrottled backgrounding
- Recommended: ForEach-Object -Parallel with bounded throttle

### Bastion Modes
- ssh/rdp: human sessions
- tunnel: automation, SCP, IDE

### Arc Run Command Caveats
- Preview status
- Agent 1.33+ required
- No portal UI
- SAS URIs for blob auth (no MI)

### SSH Key Lifecycle
- az vm user update APPENDS keys
- Full replacement requires VMAccess extension

## Examples
1. Run Command with output validation (managed execution):
   ```powershell
   $result = ./skills/vm-guest-management/Invoke-VmRunCommand.ps1 \
     -ResourceGroupName 'rg-app' \
     -VmName 'vm01' \
     -RunCommandName 'run-bootstrap' \
     -ScriptString 'echo hello && uname -a' \
     -TimeoutInSeconds 600 \
     -TreatFailureAsDeploymentFailure \
     -OutputBlobUri $env:RUNCOMMAND_OUTPUT_SAS \
     -ErrorBlobUri  $env:RUNCOMMAND_ERROR_SAS \
     -AuthContext $context

   if ($result.ExecutionState -ne 'Succeeded' -or $result.ExitCode -ne 0) {
     throw "Guest execution failed: State=$($result.ExecutionState) ExitCode=$($result.ExitCode) Error=$($result.Error)"
   }
   Write-Host $result.Output
   ```

2. Bastion tunnel for local automation:
   ```powershell
   $tunnel = ./skills/vm-guest-management/Connect-VmBastionSsh.ps1 \
     -BastionName 'hub-bastion' \
     -ResourceGroupName 'rg-hub' \
     -TargetResourceId $vmId \
     -Mode tunnel \
     -LocalPort 50022 \
     -ResourcePort 22 \
     -AuthType ssh-key \
     -Username 'azureuser' \
     -SshKeyPath '~/.ssh/id_rsa'

   Write-Host $tunnel.RecommendedCommand
   # e.g., ssh -p 50022 azureuser@127.0.0.1
   ```

3. SSH key rotation (replace prior keys):
   ```powershell
   ./skills/vm-guest-management/Invoke-VmSshKeyRotation.ps1 \
     -ResourceGroupName 'rg-app' \
     -VmNames 'vm01','vm02' \
     -PublicKeyPath '~/.ssh/id_ed25519.pub' \
     -RemovePriorKeys \
     -AuthContext $context
   ```

## Prerequisites
### Required modules
- PowerShell 7.2+
- `Az.Accounts` and `Az.Resources` (used by the shared Azure auth/REST patterns)
- Azure CLI `az` (required for Bastion connection setup)

### Required roles
- For Bastion (AAD path): **Virtual Machine Administrator Login** on the target VM
- For Run Command and SSH key management (ARM): permissions to write/execute VM Run Command and manage VMAccessForLinux extension (e.g., `Microsoft.Compute/virtualMachines/runCommand/action` and VM extension write permissions)

## Related Docs
- [Auth Patterns](../docs/auth-patterns.md)
- [Patterns and Caveats](../docs/patterns-and-caveats.md)
- [Environment Endpoints](../docs/environment-endpoints.md)

---
name: vm-guest-management
description: Use this skill for Azure VM and Arc guest execution, Bastion connectivity, and SSH key lifecycle automation.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - azure-vm
  - bastion
  - run-command
  - ssh
  - powershell
metadata:
  project: microsoft-cloud-api-skills
  domain: vm-guest-management
---

# VM Guest Management Skill

## Agent Summary
Use this skill for guest-level Azure VM or Arc machine actions such as Run Command execution, Bastion SSH or tunnel setup, and SSH key rotation. Most operations require an ARM auth context from `./skills/azure/Connect-AzureApi.ps1`, while Bastion connectivity also depends on Azure CLI.

## When to Use
- Execute an inline or file-based script on an Azure VM or Arc machine.
- Open a Bastion tunnel for SSH, SCP, SFTP, or IDE workflows.
- Rotate or replace SSH keys across one or more Linux VMs.

## Required Parameters
### `Invoke-VmRunCommand.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `ResourceGroupName` | `string` | Yes | Resource group for the target VM or Arc machine. |
| `AuthContext` | `object` | Yes | ARM auth context from `Connect-AzureApi.ps1`. |
| `VmName` | `string` | Conditional | Required for Azure VM execution unless `-IsArc` is used. |
| `MachineName` | `string` | Conditional | Required when `-IsArc` is used. |
| `ScriptString` | `string` | Conditional | Provide inline script text or use `ScriptPath`. |
| `ScriptPath` | `string` | Conditional | Local script file path; provide this or `ScriptString`. |
| `RunCommandName` | `string` | Conditional | Required for Arc managed Run Command; optional for Azure managed Run Command. |

### `Connect-VmBastionSsh.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `BastionName` | `string` | Yes | Azure Bastion host name. |
| `ResourceGroupName` | `string` | Yes | Resource group containing the Bastion host. |
| `TargetResourceId` | `string` | Yes | Resource ID of the target VM. |
| `Mode` | `string` | No | `ssh`, `rdp`, or `tunnel`; defaults to `ssh`. |
| `AuthType` | `string` | No | `ssh-key` or `AAD`; defaults to `ssh-key`. |
| `Username` | `string` | Conditional | Required for SSH key mode. |
| `SshKeyPath` | `string` | Conditional | Required for SSH key mode. |

## Example Agent Prompts
- "Run a bootstrap script on an Azure VM and return the guest output."
- "Start an Azure Bastion tunnel for this VM so I can SSH locally."
- "Rotate SSH public keys across these Linux VMs."

## Example Agent Workflow
```powershell
$ctx = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud -SubscriptionId $subscriptionId

$result = ./skills/vm-guest-management/Invoke-VmRunCommand.ps1 -ResourceGroupName "rg-app" -VmName "vm01" -ScriptString "echo hello" -AuthContext $ctx
```

## Security Caveats
- Do not treat ARM provisioning success as guest execution success; always inspect execution state and exit code.
- Prefer managed identity or federated credentials over client secrets for ARM access.
- Protect SAS URIs, SSH private keys, and break-glass accounts as sensitive credentials.

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
| **Az PowerShell modules** (`Az.Accounts`, `Az.Resources`, etc.) | Native PowerShell pipelines, object-oriented output, Azure Resource Graph | `https://management.azure.com/` (ARM) by default; `Get-AzAccessToken -ResourceTypeName MSGraph` yields Graph tokens | Heavy module dependency tree; version conflicts between `Az` and `Microsoft.Graph` modules can occur. Mitigate with `DllPickle` or `./prerequisites/Import-ConflictSafeModules.ps1`. See [docs/dll-conflict-mitigation.md](../../docs/dll-conflict-mitigation.md). |
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
- [Auth Patterns](../../docs/auth-patterns.md)
- [Patterns and Caveats](../../docs/patterns-and-caveats.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)

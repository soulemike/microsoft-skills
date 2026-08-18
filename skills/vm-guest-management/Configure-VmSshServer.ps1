#Requires -Version 7.2
<#
.SYNOPSIS
    Configures and hardens the OpenSSH server on an Azure Linux VM.

.DESCRIPTION
    Uses Azure VM Run Command to apply sshd_config hardening, host key rotation,
    and optional SSH CA configuration directly on the guest OS. This skill enables
    native direct SSH access (without Azure Bastion proxying) with a hardened posture.

    The script creates a drop-in configuration under /etc/ssh/sshd_config.d/ so
    the original sshd_config is preserved. It validates the configuration with
    sshd -t before restarting the service, and optionally verifies SSH reachability.

    Key capabilities:
    - Disable password authentication
    - Disable root login
    - Restrict allowed users/groups
    - Set MaxAuthTries, ClientAliveInterval, LoginGraceTime
    - Rotate SSH host keys
    - Configure SSH CA (TrustedUserCAKeys)
    - Validate configuration and restart sshd
    - Verify SSH port reachability after configuration

.PARAMETER ResourceGroupName
    Azure resource group that contains the target VM.

.PARAMETER VmName
    Azure virtual machine name.

.PARAMETER DisablePasswordAuth
    When specified, sets PasswordAuthentication no and KbdInteractiveAuthentication no.

.PARAMETER DisableRootLogin
    When specified, sets PermitRootLogin no.

.PARAMETER AllowUsers
    Comma-separated list of users to allow via SSH (AllowUsers directive).

.PARAMETER AllowGroups
    Comma-separated list of groups to allow via SSH (AllowGroups directive).

.PARAMETER MaxAuthTries
    Maximum authentication attempts per connection. Defaults to 3.

.PARAMETER ClientAliveInterval
    Seconds between keepalive messages. Defaults to 300 (5 minutes).

.PARAMETER LoginGraceTime
    Time allowed for authentication. Defaults to 60 seconds.

.PARAMETER RotateHostKeys
    When specified, regenerates SSH host keys (rsa, ecdsa, ed25519) and removes old keys.

.PARAMETER SshCaPublicKey
    Path to a local SSH CA public key file. When provided, configures TrustedUserCAKeys
    and AuthorizedPrincipalsFile for certificate-based SSH authentication.

.PARAMETER SshCaPrincipals
    Comma-separated list of authorized principals when using SSH CA. Defaults to the VM admin username.

.PARAMETER VerifyReachability
    When specified, probes TCP/22 from the orchestration host after configuration to confirm SSH is listening.

.PARAMETER PublicIpAddress
    Public IP address of the VM. Required when -VerifyReachability is specified.

.PARAMETER AuthContext
    Azure ARM authentication context returned by Connect-AzureApi.ps1.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/vm-guest-management/Configure-VmSshServer.ps1 `
        -ResourceGroupName 'rg-app' `
        -VmName 'vm01' `
        -DisablePasswordAuth `
        -DisableRootLogin `
        -AllowUsers 'azureuser' `
        -MaxAuthTries 3 `
        -AuthContext $context

.EXAMPLE
    ./skills/vm-guest-management/Configure-VmSshServer.ps1 `
        -ResourceGroupName 'rg-app' `
        -VmName 'vm01' `
        -DisablePasswordAuth `
        -DisableRootLogin `
        -RotateHostKeys `
        -SshCaPublicKey '~/.ssh/ca.pub' `
        -SshCaPrincipals 'admin,deploy' `
        -VerifyReachability `
        -PublicIpAddress '20.1.2.3' `
        -AuthContext $context
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [Parameter()]
    [switch]$DisablePasswordAuth,

    [Parameter()]
    [switch]$DisableRootLogin,

    [Parameter()]
    [string]$AllowUsers,

    [Parameter()]
    [string]$AllowGroups,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxAuthTries = 3,

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int]$ClientAliveInterval = 300,

    [Parameter()]
    [ValidateRange(10, 600)]
    [int]$LoginGraceTime = 60,

    [Parameter()]
    [switch]$RotateHostKeys,

    [Parameter()]
    [string]$SshCaPublicKey,

    [Parameter()]
    [string]$SshCaPrincipals,

    [Parameter()]
    [switch]$VerifyReachability,

    [Parameter()]
    [string]$PublicIpAddress,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$script:DropInFile = '/etc/ssh/sshd_config.d/50-azure-hardening.conf'
$script:CaKeysFile = '/etc/ssh/trusted-user-ca-keys.pub'
$script:PrincipalsDir = '/etc/ssh/auth_principals'
$script:SshdService = 'ssh'

function Get-AdminUsername {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    $uri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}?api-version=2024-03-01' -f
        $ArmBaseUri.TrimEnd('/'), $SubscriptionId, $ResourceGroupName, $VmName

    $vm = Invoke-SkillRestMethod -Uri $uri -Method 'GET' -AuthContext $ResolvedAuthContext
    $adminUsername = if ($vm.properties.osProfile.adminUsername) { [string]$vm.properties.osProfile.adminUsername } else { $null }

    if (-not $adminUsername) {
        throw "Could not determine adminUsername for VM '$VmName'."
    }

    return $adminUsername
}

function Get-SshCaPublicKeyContent {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -Path $resolvedPath -PathType Leaf)) {
        throw "SSH CA public key file not found: $Path"
    }

    return (Get-Content -Path $resolvedPath -Raw).Trim()
}

function Get-HardeningScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$DisablePasswordAuthFlag,

        [Parameter(Mandatory)]
        [bool]$DisableRootLoginFlag,

        [Parameter()]
        [string]$AllowUsersValue,

        [Parameter()]
        [string]$AllowGroupsValue,

        [Parameter(Mandatory)]
        [int]$MaxAuthTriesValue,

        [Parameter(Mandatory)]
        [int]$ClientAliveIntervalValue,

        [Parameter(Mandatory)]
        [int]$LoginGraceTimeValue,

        [Parameter(Mandatory)]
        [bool]$RotateHostKeysFlag,

        [Parameter()]
        [string]$SshCaPublicKeyContent,

        [Parameter()]
        [string]$SshCaPrincipalsValue,

        [Parameter(Mandatory)]
        [string]$AdminUsername
    )

    $scriptLines = [System.Collections.Generic.List[string]]::new()

    $scriptLines.Add('#!/bin/bash')
    $scriptLines.Add('set -euo pipefail')
    $scriptLines.Add("")
    $scriptLines.Add('DROP_IN_FILE="' + $script:DropInFile + '"')
    $scriptLines.Add('CA_KEYS_FILE="' + $script:CaKeysFile + '"')
    $scriptLines.Add('PRINCIPALS_DIR="' + $script:PrincipalsDir + '"')
    $scriptLines.Add("")
    $scriptLines.Add('# Ensure drop-in directory exists')
    $scriptLines.Add('install -d -m 755 "$(dirname "$DROP_IN_FILE")"')
    $scriptLines.Add("")
    $scriptLines.Add('# Build hardened configuration')
    $scriptLines.Add('cat > "$DROP_IN_FILE" << ''SSHD_EOF''')

    $scriptLines.Add('# Azure VM SSH hardening drop-in')
    $scriptLines.Add('# Generated by Microsoft Cloud API Skills / Configure-VmSshServer')

    if ($DisablePasswordAuthFlag) {
        $scriptLines.Add('PasswordAuthentication no')
        $scriptLines.Add('KbdInteractiveAuthentication no')
        $scriptLines.Add('AuthenticationMethods publickey')
    }

    if ($DisableRootLoginFlag) {
        $scriptLines.Add('PermitRootLogin no')
    }

    if (-not [string]::IsNullOrWhiteSpace($AllowUsersValue)) {
        $scriptLines.Add('AllowUsers ' + ($AllowUsersValue -replace ',', ' '))
    }

    if (-not [string]::IsNullOrWhiteSpace($AllowGroupsValue)) {
        $scriptLines.Add('AllowGroups ' + ($AllowGroupsValue -replace ',', ' '))
    }

    $scriptLines.Add('MaxAuthTries ' + $MaxAuthTriesValue)
    $scriptLines.Add('ClientAliveInterval ' + $ClientAliveIntervalValue)
    $scriptLines.Add('ClientAliveCountMax 2')
    $scriptLines.Add('LoginGraceTime ' + $LoginGraceTimeValue)
    $scriptLines.Add('MaxSessions 10')
    $scriptLines.Add('X11Forwarding no')
    $scriptLines.Add('AllowTcpForwarding yes')
    $scriptLines.Add('PermitTunnel no')
    $scriptLines.Add('Banner /etc/ssh/banner')

    if (-not [string]::IsNullOrWhiteSpace($SshCaPublicKeyContent)) {
        $scriptLines.Add('TrustedUserCAKeys "$CA_KEYS_FILE"')
        $scriptLines.Add('AuthorizedPrincipalsFile "$PRINCIPALS_DIR/%u"')
    }

    $scriptLines.Add('SSHD_EOF')
    $scriptLines.Add("")
    $scriptLines.Add('chmod 644 "$DROP_IN_FILE"')
    $scriptLines.Add("")

    if ($RotateHostKeysFlag) {
        $scriptLines.Add('# Rotate SSH host keys')
        $scriptLines.Add('rm -f /etc/ssh/ssh_host_*')
        $scriptLines.Add('ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -C "host@$(hostname)"')
        $scriptLines.Add('ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -C "host@$(hostname)"')
        $scriptLines.Add('ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -C "host@$(hostname)"')
        $scriptLines.Add('chmod 600 /etc/ssh/ssh_host_*_key')
        $scriptLines.Add('chmod 644 /etc/ssh/ssh_host_*_key.pub')
        $scriptLines.Add("")
    }

    if (-not [string]::IsNullOrWhiteSpace($SshCaPublicKeyContent)) {
        $encodedCaKey = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SshCaPublicKeyContent))
        $scriptLines.Add('# Configure SSH CA')
        $scriptLines.Add('printf ''%s'' ''' + $encodedCaKey + ''' | base64 -d > "$CA_KEYS_FILE"')
        $scriptLines.Add('chmod 644 "$CA_KEYS_FILE"')
        $scriptLines.Add('install -d -m 755 "$PRINCIPALS_DIR"')
        $scriptLines.Add("")

        $principals = if (-not [string]::IsNullOrWhiteSpace($SshCaPrincipalsValue)) {
            ($SshCaPrincipalsValue -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        } else {
            @($AdminUsername)
        }

        foreach ($principal in $principals) {
            $scriptLines.Add('echo "' + $principal + '" > "$PRINCIPALS_DIR/' + $AdminUsername + '"')
        }
        $scriptLines.Add('chmod 644 "$PRINCIPALS_DIR/' + $AdminUsername + '"')
        $scriptLines.Add("")
    }

    $scriptLines.Add('# Ensure banner file exists')
    $scriptLines.Add('touch /etc/ssh/banner')
    $scriptLines.Add('chmod 644 /etc/ssh/banner')
    $scriptLines.Add("")

    $scriptLines.Add('# Validate configuration')
    $scriptLines.Add('if ! /usr/sbin/sshd -t; then')
    $scriptLines.Add('  echo "ERROR: sshd configuration test failed" >&2')
    $scriptLines.Add('  exit 1')
    $scriptLines.Add('fi')
    $scriptLines.Add("")

    $scriptLines.Add('# Restart SSH service')
    $scriptLines.Add('if systemctl is-active --quiet ' + $script:SshdService + '; then')
    $scriptLines.Add('  systemctl restart ' + $script:SshdService)
    $scriptLines.Add('else')
    $scriptLines.Add('  systemctl start ' + $script:SshdService)
    $scriptLines.Add('fi')
    $scriptLines.Add("")

    $scriptLines.Add('# Verify service is running')
    $scriptLines.Add('if ! systemctl is-active --quiet ' + $script:SshdService + '; then')
    $scriptLines.Add('  echo "ERROR: SSH service failed to start" >&2')
    $scriptLines.Add('  exit 1')
    $scriptLines.Add('fi')
    $scriptLines.Add("")

    $scriptLines.Add('# Emit fingerprint summary')
    $scriptLines.Add('echo "SSH_HOST_KEYS_CONFIGURED=1"')
    $scriptLines.Add('for pub in /etc/ssh/ssh_host_*.pub; do')
    $scriptLines.Add('  [ -f "$pub" ] || continue')
    $scriptLines.Add('  echo "HOST_KEY:$(basename "$pub"):$(ssh-keygen -lf "$pub" | awk ''{print $2}'')"')
    $scriptLines.Add('done')
    $scriptLines.Add('echo "SSH_SERVER_CONFIGURED=1"')

    return $scriptLines -join "`n"
}

function Test-SshReachability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IpAddress,

        [Parameter()]
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $tcpClient = [System.Net.Sockets.TcpClient]::new()
            $connectTask = $tcpClient.ConnectAsync($IpAddress, 22)
            $completed = $connectTask.Wait(5000)
            if ($completed -and $tcpClient.Connected) {
                $tcpClient.Close()
                return $true
            }
            $tcpClient.Close()
        }
        catch {
            # Continue polling — port not yet reachable
            Write-Verbose 'SSH port check failed, continuing to poll' -Verbose
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

try {
    if ($VerifyReachability -and [string]::IsNullOrWhiteSpace($PublicIpAddress)) {
        throw 'PublicIpAddress is required when -VerifyReachability is specified.'
    }

    $resolvedAuthContext = if ($AuthContext -is [hashtable]) { @{} + $AuthContext } else {
        $table = @{}; foreach ($p in $AuthContext.PSObject.Properties) { $table[$p.Name] = $p.Value }; $table
    }

    $environment = if ($resolvedAuthContext.ContainsKey('Environment') -and $resolvedAuthContext.Environment) {
        [string]$resolvedAuthContext.Environment
    } else { 'AzureCloud' }

    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    $resolvedAuthContext = Resolve-AuthContext -AuthContext $resolvedAuthContext -Resource "$($endpoints.Arm)/"

    if (-not $resolvedAuthContext.ContainsKey('SubscriptionId') -or [string]::IsNullOrWhiteSpace([string]$resolvedAuthContext.SubscriptionId)) {
        throw 'AuthContext.SubscriptionId is required for VM SSH server configuration.'
    }

    $subscriptionId = [string]$resolvedAuthContext.SubscriptionId
    $adminUsername = Get-AdminUsername -ArmBaseUri $endpoints.Arm -SubscriptionId $subscriptionId -ResolvedAuthContext $resolvedAuthContext

    $caKeyContent = Get-SshCaPublicKeyContent -Path $SshCaPublicKey

    $hardeningScript = Get-HardeningScript `
        -DisablePasswordAuthFlag $DisablePasswordAuth.IsPresent `
        -DisableRootLoginFlag $DisableRootLogin.IsPresent `
        -AllowUsersValue $AllowUsers `
        -AllowGroupsValue $AllowGroups `
        -MaxAuthTriesValue $MaxAuthTries `
        -ClientAliveIntervalValue $ClientAliveInterval `
        -LoginGraceTimeValue $LoginGraceTime `
        -RotateHostKeysFlag $RotateHostKeys.IsPresent `
        -SshCaPublicKeyContent $caKeyContent `
        -SshCaPrincipalsValue $SshCaPrincipals `
        -AdminUsername $adminUsername

    $invokeVmRunCommandPath = Join-Path $PSScriptRoot 'Invoke-VmRunCommand.ps1'
    if (-not (Test-Path -Path $invokeVmRunCommandPath -PathType Leaf)) {
        throw "Required script not found: $invokeVmRunCommandPath"
    }

    $runResult = & $invokeVmRunCommandPath `
        -ResourceGroupName $ResourceGroupName `
        -VmName $VmName `
        -ScriptString $hardeningScript `
        -AuthContext $resolvedAuthContext

    $hostKeys = [System.Collections.Generic.List[hashtable]]::new()
    $configured = $false

    if ($runResult.Output) {
        foreach ($line in ($runResult.Output -split "`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -eq 'SSH_SERVER_CONFIGURED=1') {
                $configured = $true
            }
            elseif ($trimmed -match '^HOST_KEY:(?<file>[^:]+):(?<fingerprint>[A-Fa-f0-9:]+)$') {
                [void]$hostKeys.Add(@{
                    File = $Matches.file
                    Fingerprint = $Matches.fingerprint
                })
            }
        }
    }

    $reachabilityResult = $null
    if ($VerifyReachability) {
        $reachabilityResult = Test-SshReachability -IpAddress $PublicIpAddress -TimeoutSeconds 60
    }

    return [pscustomobject][ordered]@{
        VmName = $VmName
        ResourceGroupName = $ResourceGroupName
        AdminUsername = $adminUsername
        SshConfigured = $configured
        SshdTestPassed = ($runResult.ExitCode -eq 0 -or $runResult.ExecutionState -eq 'Succeeded')
        ServiceRestarted = $configured
        HostKeys = @($hostKeys)
        HostKeysRotated = $RotateHostKeys.IsPresent
        PasswordAuthDisabled = $DisablePasswordAuth.IsPresent
        RootLoginDisabled = $DisableRootLogin.IsPresent
        SshCaConfigured = (-not [string]::IsNullOrWhiteSpace($caKeyContent))
        ReachabilityVerified = $reachabilityResult
        RunCommandResult = [pscustomobject][ordered]@{
            ExecutionState = $runResult.ExecutionState
            ExitCode = $runResult.ExitCode
            Succeeded = $runResult.Succeeded
        }
        Timestamp = [datetime]::UtcNow
    }
}
catch {
    $message = "Failed to configure SSH server on VM '$VmName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

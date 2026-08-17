#Requires -Version 7.2
<#
.SYNOPSIS
    Opens an Azure Bastion native client connection or tunnel.

.DESCRIPTION
    Constructs and runs the appropriate Azure CLI native client command for
    Azure Bastion SSH, RDP, or tunnel access. The script is intended as a thin
    convenience wrapper around:

    - az network bastion ssh
    - az network bastion rdp
    - az network bastion tunnel

    SSH and RDP modes run the Azure CLI command directly. Tunnel mode starts the
    tunnel in the background and returns connection metadata so callers can use
    standard local SSH, RDP, SCP, SFTP, or IDE tooling against 127.0.0.1.

.PARAMETER BastionName
    Azure Bastion host name.

.PARAMETER ResourceGroupName
    Resource group that contains the Bastion host.

.PARAMETER TargetResourceId
    Resource ID of the target virtual machine.

.PARAMETER Mode
    Connection mode. Valid values are ssh, rdp, and tunnel. Defaults to ssh.

.PARAMETER AuthType
    Authentication mode hint. Valid values are ssh-key and AAD. Defaults to
    ssh-key. For RDP mode, AAD maps to --enable-mfa true because az network
    bastion rdp does not expose --auth-type.

.PARAMETER Username
    Username to use for SSH mode or in the recommended post-tunnel SSH command.

.PARAMETER SshKeyPath
    Path to the private SSH key file used by az network bastion ssh in ssh-key
    mode.

.PARAMETER LocalPort
    Local tunnel port when Mode is tunnel. Defaults to 50022.

.PARAMETER ResourcePort
    Port on the target resource. Defaults to 22 for ssh/tunnel and 3389 for rdp.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/vm-guest-management/Connect-VmBastionSsh.ps1 \
        -BastionName 'hub-bastion' \
        -ResourceGroupName 'rg-hub' \
        -TargetResourceId $vmId \
        -Mode ssh \
        -AuthType ssh-key \
        -Username azureuser \
        -SshKeyPath '~/.ssh/id_rsa'

.EXAMPLE
    ./skills/vm-guest-management/Connect-VmBastionSsh.ps1 \
        -BastionName 'hub-bastion' \
        -ResourceGroupName 'rg-hub' \
        -TargetResourceId $vmId \
        -Mode tunnel \
        -LocalPort 50022 \
        -ResourcePort 22
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BastionName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetResourceId,

    [Parameter()]
    [ValidateSet('ssh', 'rdp', 'tunnel')]
    [string]$Mode = 'ssh',

    [Parameter()]
    [ValidateSet('ssh-key', 'AAD')]
    [string]$AuthType = 'ssh-key',

    [Parameter()]
    [string]$Username,

    [Parameter()]
    [string]$SshKeyPath,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$LocalPort = 50022,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$ResourcePort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HasResourcePort = $PSBoundParameters.ContainsKey('ResourcePort')

function Test-CommandAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    return $null -ne (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
}

function Get-EffectiveResourcePort {
    [CmdletBinding()]
    param()

    if ($script:HasResourcePort) {
        return $ResourcePort
    }

    if ($Mode -eq 'rdp') {
        return 3389
    }

    return 22
}

function Get-AzureCliArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$EffectiveResourcePort
    )

    $argumentItems = [System.Collections.Generic.List[string]]::new()
    $argumentItems.Add('network')
    $argumentItems.Add('bastion')
    $argumentItems.Add($Mode)
    $argumentItems.Add('--name')
    $argumentItems.Add($BastionName)
    $argumentItems.Add('--resource-group')
    $argumentItems.Add($ResourceGroupName)
    $argumentItems.Add('--target-resource-id')
    $argumentItems.Add($TargetResourceId)

    switch ($Mode) {
        'ssh' {
            $argumentItems.Add('--resource-port')
            $argumentItems.Add([string]$EffectiveResourcePort)
            $argumentItems.Add('--auth-type')
            $argumentItems.Add($AuthType)

            if ($Username) {
                $argumentItems.Add('--username')
                $argumentItems.Add($Username)
            }

            if ($AuthType -eq 'ssh-key') {
                if ([string]::IsNullOrWhiteSpace($Username)) {
                    throw 'Username is required for ssh mode when -AuthType ssh-key is used.'
                }

                if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
                    throw 'SshKeyPath is required for ssh mode when -AuthType ssh-key is used.'
                }

                if (-not (Test-Path -Path $SshKeyPath -PathType Leaf)) {
                    throw "SshKeyPath was not found: $SshKeyPath"
                }

                $argumentItems.Add('--ssh-key')
                $argumentItems.Add((Resolve-Path -Path $SshKeyPath).Path)
            }
        }
        'rdp' {
            $argumentItems.Add('--resource-port')
            $argumentItems.Add([string]$EffectiveResourcePort)

            if ($AuthType -eq 'AAD') {
                $argumentItems.Add('--enable-mfa')
                $argumentItems.Add('true')
            }
        }
        'tunnel' {
            $argumentItems.Add('--port')
            $argumentItems.Add([string]$LocalPort)
            $argumentItems.Add('--resource-port')
            $argumentItems.Add([string]$EffectiveResourcePort)
        }
    }

    return $argumentItems
}

function Get-CommandPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $segments = foreach ($item in $ArgumentList) {
        if ($item -match '\s') {
            '"{0}"' -f $item.Replace('"', '\"')
        }
        else {
            $item
        }
    }

    return 'az {0}' -f ($segments -join ' ')
}

try {
    if (-not (Test-CommandAvailable -CommandName 'az')) {
        throw 'Azure CLI (az) is required but was not found in PATH.'
    }

    $effectiveResourcePort = Get-EffectiveResourcePort
    $argumentList = Get-AzureCliArgumentList -EffectiveResourcePort $effectiveResourcePort
    $commandPreview = Get-CommandPreview -ArgumentList $argumentList

    if ($Mode -eq 'tunnel') {
        $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("bastion-tunnel-{0}.stdout.log" -f ([guid]::NewGuid().ToString('n')))
        $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("bastion-tunnel-{0}.stderr.log" -f ([guid]::NewGuid().ToString('n')))

        $process = Start-Process -FilePath 'az' -ArgumentList $argumentList -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        Start-Sleep -Seconds 3

        if ($process.HasExited) {
            $errorDetails = if (Test-Path -Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { $null }
            throw "Azure Bastion tunnel failed to start. $errorDetails"
        }

        $recommendedCommand = if ($effectiveResourcePort -eq 22 -and $Username) {
            "ssh -p $LocalPort $Username@127.0.0.1"
        }
        elseif ($effectiveResourcePort -eq 3389) {
            "Connect your RDP client to 127.0.0.1:$LocalPort"
        }
        else {
            "Connect your client to 127.0.0.1:$LocalPort"
        }

        return [pscustomobject][ordered]@{
            Mode = $Mode
            AuthType = $AuthType
            BastionName = $BastionName
            ResourceGroupName = $ResourceGroupName
            TargetResourceId = $TargetResourceId
            LocalAddress = '127.0.0.1'
            LocalPort = $LocalPort
            ResourcePort = $effectiveResourcePort
            ProcessId = $process.Id
            Command = $commandPreview
            StdOutLogPath = $stdoutPath
            StdErrLogPath = $stderrPath
            RecommendedCommand = $recommendedCommand
            Status = 'TunnelStarted'
        }
    }

    & az @argumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Azure CLI exited with code $exitCode."
    }

    return [pscustomobject][ordered]@{
        Mode = $Mode
        AuthType = $AuthType
        BastionName = $BastionName
        ResourceGroupName = $ResourceGroupName
        TargetResourceId = $TargetResourceId
        ResourcePort = $effectiveResourcePort
        Command = $commandPreview
        ExitCode = $exitCode
        Status = 'Completed'
    }
}
catch {
    $message = "Failed to establish Azure Bastion $Mode connection through Bastion '$BastionName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

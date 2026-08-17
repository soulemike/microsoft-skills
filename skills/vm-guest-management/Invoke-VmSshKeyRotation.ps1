#Requires -Version 7.2
<#
.SYNOPSIS
    Rotates or injects SSH public keys for one or more Azure virtual machines.

.DESCRIPTION
    Implements SSH key lifecycle patterns called out in the project VM Guest
    Management guidance.

    Important behavior:
    - The Azure CLI command az vm user update appends a key to
      ~/.ssh/authorized_keys; it does not remove prior keys.
    - This script uses an append-only guest script when -RemovePriorKeys is not
      specified.
    - When -RemovePriorKeys is specified, the script uses the VMAccessForLinux
      extension so old keys can be removed as part of the update.
    - When -CreateTempUser is specified, the script creates a temporary
      break-glass user pattern by using VMAccessForLinux with an expiration date.

    For multi-VM execution, the script uses a bounded parallel fan-out by
    recursively invoking itself per target with ForEach-Object -Parallel and a
    throttle limit.

.PARAMETER ResourceGroupName
    Azure resource group that contains the target virtual machines.

.PARAMETER VmName
    Single VM name.

.PARAMETER VmNames
    One or more VM names for bounded parallel execution.

.PARAMETER PublicKeyPath
    Path to the new SSH public key file.

.PARAMETER RemovePriorKeys
    Uses the VMAccessForLinux extension with remove_prior_keys=true so existing
    SSH keys for the target account are replaced instead of appended to.

.PARAMETER CreateTempUser
    Creates a temporary emergency-access user and applies the supplied SSH key to
    that account by using the VMAccessForLinux extension.

.PARAMETER AuthContext
    Azure ARM authentication context returned by Connect-AzureApi.ps1.

.OUTPUTS
    PSCustomObject[]

.EXAMPLE
    ./skills/vm-guest-management/Invoke-VmSshKeyRotation.ps1 \
        -ResourceGroupName 'rg-app' \
        -VmName 'vm01' \
        -PublicKeyPath '~/.ssh/id_ed25519.pub' \
        -AuthContext $context

.EXAMPLE
    ./skills/vm-guest-management/Invoke-VmSshKeyRotation.ps1 \
        -ResourceGroupName 'rg-app' \
        -VmNames 'vm01','vm02','vm03' \
        -PublicKeyPath '~/.ssh/id_ed25519.pub' \
        -RemovePriorKeys \
        -AuthContext $context
#>
[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(ParameterSetName = 'Single')]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [Parameter(ParameterSetName = 'Multiple')]
    [ValidateNotNullOrEmpty()]
    [string[]]$VmNames,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PublicKeyPath,

    [Parameter()]
    [switch]$RemovePriorKeys,

    [Parameter()]
    [switch]$CreateTempUser,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$script:VmApiVersion = '2024-03-01'
$script:VmExtensionApiVersion = '2024-11-01'
$script:ParallelThrottleLimit = 5
$script:VmAccessExtensionName = 'enablevmaccess'

function ConvertTo-AuthHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($InputObject -is [hashtable]) {
        return @{} + $InputObject
    }

    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }

    return $table
}

function Get-EnvironmentFromAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    if ($ResolvedAuthContext.ContainsKey('Environment') -and -not [string]::IsNullOrWhiteSpace([string]$ResolvedAuthContext.Environment)) {
        return [string]$ResolvedAuthContext.Environment
    }

    return 'AzureCloud'
}

function Get-ArmSubscriptionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    if ($ResolvedAuthContext.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace([string]$ResolvedAuthContext.SubscriptionId)) {
        return [string]$ResolvedAuthContext.SubscriptionId
    }

    throw 'AuthContext.SubscriptionId is required for SSH key rotation operations.'
}

function Get-TargetVmNameCollection {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SingleVmName,

        [Parameter()]
        [string[]]$MultipleVmNames
    )

    $names = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($SingleVmName)) {
        $names.Add($SingleVmName)
    }

    foreach ($name in @($MultipleVmNames)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names.Add($name)
        }
    }

    $uniqueNames = @($names | Select-Object -Unique)
    if ($uniqueNames.Count -eq 0) {
        throw 'Specify -VmName or -VmNames.'
    }

    return $uniqueNames
}

function Get-VmDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    $uri = (
        '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}?api-version={4}' -f
        $ArmBaseUri.TrimEnd('/'),
        $SubscriptionId,
        $ResourceGroupName,
        $VmName,
        $script:VmApiVersion
    )

    return Invoke-SkillRestMethod -Uri $uri -Method 'GET' -AuthContext $ResolvedAuthContext
}

function Get-AccountNameForRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$VmResource
    )

    if ($CreateTempUser) {
        return ('temp-{0}' -f ([guid]::NewGuid().ToString('n').Substring(0, 8)))
    }

    if (-not $VmResource.properties.osProfile.adminUsername) {
        throw 'VM properties.osProfile.adminUsername was not present, so the target account could not be inferred.'
    }

    return [string]$VmResource.properties.osProfile.adminUsername
}

function Get-AppendKeyScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$PublicKeyContent
    )

    $encodedKey = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($PublicKeyContent))

    return (@'
set -euo pipefail
target_user='__USERNAME__'
home_dir="$(getent passwd "$target_user" | cut -d: -f6)"

if [ -z "$home_dir" ]; then
  echo "User '$target_user' was not found on the VM." >&2
  exit 1
fi

target_group="$(id -gn "$target_user")"
install -d -m 700 -o "$target_user" -g "$target_group" "$home_dir/.ssh"
auth_keys="$home_dir/.ssh/authorized_keys"
touch "$auth_keys"
key="$(printf '%s' '__ENCODED_KEY__' | base64 -d)"

if ! grep -qxF "$key" "$auth_keys"; then
  printf '%s\n' "$key" >> "$auth_keys"
fi

chown "$target_user":"$target_group" "$auth_keys"
chmod 600 "$auth_keys"
echo "SSH public key ensured for $target_user"
'@).Replace('__USERNAME__', $Username).Replace('__ENCODED_KEY__', $encodedKey)
}

function Wait-ForExtensionProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [string]$VmName
    )

    $deadline = (Get-Date).AddMinutes(10)

    do {
        $extension = Invoke-SkillRestMethod -Uri $Uri -Method 'GET' -AuthContext $ResolvedAuthContext
        $state = if ($extension.properties.provisioningState) { [string]$extension.properties.provisioningState } else { $null }
        if ($state -in @('Succeeded', 'Failed', 'Canceled')) {
            return $extension
        }

        if ((Get-Date) -ge $deadline) {
            throw "Timed out while waiting for VMAccess extension on '$VmName'."
        }

        Start-Sleep -Seconds 5
    }
    while ($true)
}

function Invoke-VmAccessRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$VmResource,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$PublicKeyContent,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    $protectedSettings = [ordered]@{
        username = $Username
        ssh_key = $PublicKeyContent
    }

    if ($RemovePriorKeys.IsPresent) {
        $protectedSettings.remove_prior_keys = $true
    }

    $expiration = $null
    if ($CreateTempUser.IsPresent) {
        $expiration = (Get-Date).AddDays(7).ToString('yyyy-MM-dd')
        $protectedSettings.expiration = $expiration
    }

    $uri = (
        '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}/extensions/{4}?api-version={5}' -f
        $ArmBaseUri.TrimEnd('/'),
        $SubscriptionId,
        $ResourceGroupName,
        $VmName,
        $script:VmAccessExtensionName,
        $script:VmExtensionApiVersion
    )

    $body = [ordered]@{
        location = $VmResource.location
        properties = [ordered]@{
            publisher = 'Microsoft.OSTCExtensions'
            type = 'VMAccessForLinux'
            typeHandlerVersion = '1.5'
            autoUpgradeMinorVersion = $true
            forceUpdateTag = [guid]::NewGuid().ToString()
            settings = @{}
            protectedSettings = $protectedSettings
        }
    }

    $null = Invoke-SkillRestMethod -Uri $uri -Method 'PUT' -Body $body -AuthContext $ResolvedAuthContext
    $extension = Wait-ForExtensionProvisioning -Uri $uri -ResolvedAuthContext $ResolvedAuthContext -VmName $VmName

    return [pscustomobject][ordered]@{
        VmName = $VmName
        ResourceGroupName = $ResourceGroupName
        Username = $Username
        TempUser = $CreateTempUser.IsPresent
        Expiration = $expiration
        RemovePriorKeys = $RemovePriorKeys.IsPresent
        Mode = 'VMAccessExtension'
        ProvisioningState = [string]$extension.properties.provisioningState
        Status = if ($extension.properties.provisioningState -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
        AppendOnly = $false
        Notes = if ($CreateTempUser) {
            'Created or updated a temporary break-glass user through VMAccessForLinux.'
        }
        elseif ($RemovePriorKeys) {
            'Rotated SSH key through VMAccessForLinux with remove_prior_keys=true.'
        }
        else {
            'Updated SSH key through VMAccessForLinux.'
        }
    }
}

function Invoke-AppendRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$PublicKeyContent,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    Write-Warning 'Append-only rotation is in use. This mirrors az vm user update behavior and does not remove stale keys. Use -RemovePriorKeys for VMAccess-based key replacement.'

    $invokeVmRunCommandPath = Join-Path $PSScriptRoot 'Invoke-VmRunCommand.ps1'
    if (-not (Test-Path -Path $invokeVmRunCommandPath -PathType Leaf)) {
        throw "Required script not found: $invokeVmRunCommandPath"
    }

    $scriptContent = Get-AppendKeyScript -Username $Username -PublicKeyContent $PublicKeyContent
    $result = & $invokeVmRunCommandPath -ResourceGroupName $ResourceGroupName -VmName $VmName -ScriptString $scriptContent -AuthContext $ResolvedAuthContext

    return [pscustomobject][ordered]@{
        VmName = $VmName
        ResourceGroupName = $ResourceGroupName
        Username = $Username
        TempUser = $false
        Expiration = $null
        RemovePriorKeys = $false
        Mode = 'RunCommandAppend'
        ProvisioningState = $result.ProvisioningState
        Status = if ($result.Succeeded) { 'Succeeded' } else { 'Failed' }
        AppendOnly = $true
        ExitCode = $result.ExitCode
        ExecutionState = $result.ExecutionState
        Output = $result.Output
        Error = $result.Error
        Notes = 'Appended SSH key without removing existing authorized_keys entries. This is safer for routine access updates but not a full key replacement.'
    }
}

function Invoke-SingleVmRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedVmName,

        [Parameter(Mandatory)]
        [string]$PublicKeyContent,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    try {
        $vmResource = Get-VmDetail -VmName $ResolvedVmName -ArmBaseUri $ArmBaseUri -SubscriptionId $SubscriptionId -ResolvedAuthContext $ResolvedAuthContext
        $osType = if ($vmResource.properties.storageProfile.osDisk.osType) { [string]$vmResource.properties.storageProfile.osDisk.osType } else { $null }
        if ($osType -ne 'Linux') {
            throw "SSH key rotation only supports Linux VMs. Detected OS type: '$osType'."
        }

        $username = Get-AccountNameForRotation -VmResource $vmResource

        if ($RemovePriorKeys -or $CreateTempUser) {
            return Invoke-VmAccessRotation -VmResource $vmResource -VmName $ResolvedVmName -ArmBaseUri $ArmBaseUri -SubscriptionId $SubscriptionId -Username $username -PublicKeyContent $PublicKeyContent -ResolvedAuthContext $ResolvedAuthContext
        }

        return Invoke-AppendRotation -VmName $ResolvedVmName -Username $username -PublicKeyContent $PublicKeyContent -ResolvedAuthContext $ResolvedAuthContext
    }
    catch {
        return [pscustomobject][ordered]@{
            VmName = $ResolvedVmName
            ResourceGroupName = $ResourceGroupName
            Username = $null
            TempUser = $CreateTempUser.IsPresent
            Expiration = $null
            RemovePriorKeys = $RemovePriorKeys.IsPresent
            Mode = if ($RemovePriorKeys -or $CreateTempUser) { 'VMAccessExtension' } else { 'RunCommandAppend' }
            ProvisioningState = 'Failed'
            Status = 'Failed'
            AppendOnly = (-not $RemovePriorKeys.IsPresent -and -not $CreateTempUser.IsPresent)
            ExitCode = $null
            ExecutionState = 'Failed'
            Output = $null
            Error = $_.Exception.Message
            Notes = 'Per-VM rotation failed.'
        }
    }
}

try {
    if (-not (Test-Path -Path $PublicKeyPath -PathType Leaf)) {
        throw "PublicKeyPath was not found: $PublicKeyPath"
    }

    $publicKeyContent = (Get-Content -Path $PublicKeyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($publicKeyContent)) {
        throw 'PublicKeyPath must contain a non-empty SSH public key.'
    }

    $targetVmNames = Get-TargetVmNameCollection -SingleVmName $VmName -MultipleVmNames $VmNames
    $resolvedAuthContext = ConvertTo-AuthHashtable -InputObject $AuthContext
    $environment = Get-EnvironmentFromAuthContext -ResolvedAuthContext $resolvedAuthContext
    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    $resolvedAuthContext = Resolve-AuthContext -AuthContext $resolvedAuthContext -Resource "$($endpoints.Arm)/"
    $subscriptionId = Get-ArmSubscriptionId -ResolvedAuthContext $resolvedAuthContext

    if ($targetVmNames.Count -eq 1) {
        return Invoke-SingleVmRotation -ResolvedVmName $targetVmNames[0] -PublicKeyContent $publicKeyContent -ResolvedAuthContext $resolvedAuthContext -ArmBaseUri $endpoints.Arm -SubscriptionId $subscriptionId
    }

    $scriptPath = $PSCommandPath
    $removePriorKeysEnabled = $RemovePriorKeys.IsPresent
    $createTempUserEnabled = $CreateTempUser.IsPresent
    $results = $targetVmNames | ForEach-Object -Parallel {
        & $using:scriptPath -ResourceGroupName $using:ResourceGroupName -VmName $_ -PublicKeyPath $using:PublicKeyPath -AuthContext $using:resolvedAuthContext -RemovePriorKeys:$using:removePriorKeysEnabled -CreateTempUser:$using:createTempUserEnabled
    } -ThrottleLimit $script:ParallelThrottleLimit

    return @($results)
}
catch {
    $message = "Failed to rotate SSH keys for resource group '$ResourceGroupName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

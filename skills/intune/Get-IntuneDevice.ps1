#Requires -Version 7.2
<#
.SYNOPSIS
    Gets Microsoft Intune managed devices.

.DESCRIPTION
    Retrieves Microsoft Intune managed devices through Microsoft Graph. When
    DeviceId is omitted, the script lists devices using a lightweight $select set
    by default. When DeviceId is provided, the script retrieves a single managed
    device and applies the requested $select projection.

    Important Intune caveat: the managedDevices collection endpoint returns
    default, null, or empty values for several properties such as
    activationLockBypassCode, hardwareInformation, notes, iccid, udid,
    ethernetMacAddress, physicalMemoryInBytes, and
    remoteAssistanceSessionUrl. To retrieve true values for those properties,
    perform a per-device GET by specifying -DeviceId and use -Select to request
    the needed fields. The hardwareInformation property may require the beta
    Graph endpoint.

.PARAMETER DeviceId
    Optional Intune managed device identifier.

.PARAMETER Select
    Optional array of properties to request through $select, for example
    @('id', 'deviceName', 'hardwareInformation'). When omitted, the script uses a
    lightweight default set for list operations and a broader detail-oriented set
    for single-device retrieval.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.OUTPUTS
    System.Object

.EXAMPLE
    ./skills/intune/Get-IntuneDevice.ps1 -AuthContext $context

.EXAMPLE
    ./skills/intune/Get-IntuneDevice.ps1 -DeviceId $deviceId -Select @('id', 'deviceName', 'hardwareInformation') -AuthContext $context
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Select,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$invokeIntuneGraphRequestPath = Join-Path $PSScriptRoot 'Invoke-IntuneGraphRequest.ps1'
if (-not (Test-Path -Path $invokeIntuneGraphRequestPath -PathType Leaf)) {
    throw "Required script not found: $invokeIntuneGraphRequestPath"
}

function Get-DefaultListSelect {
    [CmdletBinding()]
    param()

    return @(
        'id'
        'deviceName'
        'operatingSystem'
        'complianceState'
        'managementAgent'
        'lastSyncDateTime'
        'userPrincipalName'
    )
}

function Get-DefaultDetailSelect {
    [CmdletBinding()]
    param()

    return @(
        'id'
        'deviceName'
        'operatingSystem'
        'complianceState'
        'managementAgent'
        'lastSyncDateTime'
        'userPrincipalName'
        'activationLockBypassCode'
        'hardwareInformation'
        'notes'
        'iccid'
        'udid'
        'ethernetMacAddress'
        'physicalMemoryInBytes'
        'remoteAssistanceSessionUrl'
    )
}

function ConvertTo-SelectQueryString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Properties
    )

    $distinctProperties = $Properties | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    if (-not $distinctProperties) {
        return $null
    }

    return [System.Uri]::EscapeDataString(($distinctProperties -join ','))
}

function Get-ManagedDeviceApiVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Properties
    )

    if ($Properties -contains 'hardwareInformation') {
        return 'beta'
    }

    return 'v1.0'
}

function ConvertFrom-IntuneCollectionResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response -is [System.Array]) {
        return $Response
    }

    if ($Response -and $Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }

    return @($Response)
}

try {
    $selectedProperties = if ($PSBoundParameters.ContainsKey('Select')) {
        $Select
    }
    elseif ($PSBoundParameters.ContainsKey('DeviceId')) {
        Get-DefaultDetailSelect
    }
    else {
        Get-DefaultListSelect
    }

    $apiVersion = Get-ManagedDeviceApiVersion -Properties $selectedProperties
    $selectQuery = ConvertTo-SelectQueryString -Properties $selectedProperties

    $requestUri = if ($PSBoundParameters.ContainsKey('DeviceId')) {
        if ($selectQuery) {
            "/managedDevices/$DeviceId?`$select=$selectQuery"
        }
        else {
            "/managedDevices/$DeviceId"
        }
    }
    else {
        if ($selectQuery) {
            "/managedDevices?`$select=$selectQuery"
        }
        else {
            '/managedDevices'
        }
    }

    $response = & $invokeIntuneGraphRequestPath -Uri $requestUri -Method 'GET' -ApiVersion $apiVersion -AuthContext $AuthContext

    if ($PSBoundParameters.ContainsKey('DeviceId')) {
        return $response
    }

    return ConvertFrom-IntuneCollectionResponse -Response $response
}
catch {
    $message = if ($PSBoundParameters.ContainsKey('DeviceId')) {
        "Failed to retrieve Intune managed device '$DeviceId'. $($_.Exception.Message)"
    }
    else {
        'Failed to list Intune managed devices. {0}' -f $_.Exception.Message
    }

    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

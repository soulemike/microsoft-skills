#Requires -Version 7.2
<#
.SYNOPSIS
    Gets Microsoft Intune configuration and compliance policies.

.DESCRIPTION
    Retrieves Microsoft Intune policy metadata for classic device configuration
    policies, classic device compliance policies, and modern settings catalog
    configuration policies. The script automatically uses Microsoft Graph beta
    for PolicyType configurationPolicy because
    /deviceManagement/configurationPolicies is a beta-required Intune surface.

    When IncludeSettings is specified, the script retrieves the policy settings
    child collection from /settings. This switch is only supported for
    PolicyType configurationPolicy because settings catalog detail lives on the
    beta settings child endpoint. When IncludeAssignments is specified, the
    script retrieves the /assignments child collection.

    Important Intune caveat: list responses provide policy metadata, but detailed
    operational data often lives in child endpoints. Settings catalog policy
    settings require beta.

.PARAMETER PolicyId
    Optional policy identifier. When omitted, the script lists policies for the
    selected PolicyType.

.PARAMETER PolicyType
    The Intune policy type to retrieve. deviceConfiguration maps to
    /deviceManagement/deviceConfigurations, deviceCompliance maps to
    /deviceManagement/deviceCompliancePolicies, and configurationPolicy maps to
    /deviceManagement/configurationPolicies on the beta endpoint.

.PARAMETER IncludeSettings
    Retrieves the /settings child endpoint. This switch is valid only for
    PolicyType configurationPolicy.

.PARAMETER IncludeAssignments
    Retrieves the /assignments child endpoint.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.OUTPUTS
    System.Object

.EXAMPLE
    ./skills/intune/Get-IntuneConfigurationPolicy.ps1 -PolicyType deviceConfiguration -AuthContext $context

.EXAMPLE
    ./skills/intune/Get-IntuneConfigurationPolicy.ps1 -PolicyType configurationPolicy -IncludeSettings -IncludeAssignments -AuthContext $context
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PolicyId,

    [Parameter()]
    [ValidateSet('deviceConfiguration', 'deviceCompliance', 'configurationPolicy')]
    [string]$PolicyType = 'deviceConfiguration',

    [Parameter()]
    [switch]$IncludeSettings,

    [Parameter()]
    [switch]$IncludeAssignments,

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

function Get-PolicyEndpointName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestedPolicyType
    )

    switch ($RequestedPolicyType) {
        'deviceConfiguration' { return 'deviceConfigurations' }
        'deviceCompliance' { return 'deviceCompliancePolicies' }
        'configurationPolicy' { return 'configurationPolicies' }
        default { throw "Unsupported policy type '$RequestedPolicyType'." }
    }
}

function Get-PolicyApiVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestedPolicyType
    )

    if ($RequestedPolicyType -eq 'configurationPolicy') {
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

function Invoke-PolicyRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [string]$RequestedApiVersion
    )

    return & $invokeIntuneGraphRequestPath -Uri $RequestUri -Method 'GET' -ApiVersion $RequestedApiVersion -AuthContext $AuthContext
}

function Add-PolicyChildData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Policy,

        [Parameter(Mandatory)]
        [string]$EndpointName,

        [Parameter(Mandatory)]
        [string]$RequestedApiVersion
    )

    if (-not $Policy.id) {
        throw 'The policy object does not contain an id value.'
    }

    if ($IncludeSettings) {
        if ($PolicyType -ne 'configurationPolicy') {
            throw 'IncludeSettings is supported only when PolicyType is configurationPolicy because the /settings child endpoint is a beta settings catalog surface.'
        }

        $settingsResponse = Invoke-PolicyRequest -RequestUri "/$EndpointName/$($Policy.id)/settings?`$expand=settingDefinitions" -RequestedApiVersion $RequestedApiVersion
        $settings = ConvertFrom-IntuneCollectionResponse -Response $settingsResponse
        $Policy | Add-Member -NotePropertyName 'settings' -NotePropertyValue $settings -Force
    }

    if ($IncludeAssignments) {
        $assignmentsResponse = Invoke-PolicyRequest -RequestUri "/$EndpointName/$($Policy.id)/assignments" -RequestedApiVersion $RequestedApiVersion
        $assignments = ConvertFrom-IntuneCollectionResponse -Response $assignmentsResponse
        $Policy | Add-Member -NotePropertyName 'assignments' -NotePropertyValue $assignments -Force
    }

    return $Policy
}

try {
    if ($IncludeSettings -and $PolicyType -ne 'configurationPolicy') {
        throw 'IncludeSettings is supported only for PolicyType configurationPolicy.'
    }

    $endpointName = Get-PolicyEndpointName -RequestedPolicyType $PolicyType
    $apiVersion = Get-PolicyApiVersion -RequestedPolicyType $PolicyType

    if ($PSBoundParameters.ContainsKey('PolicyId')) {
        $policy = Invoke-PolicyRequest -RequestUri "/$endpointName/$PolicyId" -RequestedApiVersion $apiVersion

        if ($IncludeSettings -or $IncludeAssignments) {
            return Add-PolicyChildData -Policy $policy -EndpointName $endpointName -RequestedApiVersion $apiVersion
        }

        return $policy
    }

    $policies = ConvertFrom-IntuneCollectionResponse -Response (Invoke-PolicyRequest -RequestUri "/$endpointName" -RequestedApiVersion $apiVersion)

    if (-not $IncludeSettings -and -not $IncludeAssignments) {
        return $policies
    }

    $enrichedPolicies = [System.Collections.Generic.List[object]]::new()
    foreach ($policy in $policies) {
        [void]$enrichedPolicies.Add((Add-PolicyChildData -Policy $policy -EndpointName $endpointName -RequestedApiVersion $apiVersion))
    }

    return $enrichedPolicies
}
catch {
    $message = if ($PSBoundParameters.ContainsKey('PolicyId')) {
        "Failed to retrieve Intune policy '$PolicyId' for policy type '$PolicyType'. $($_.Exception.Message)"
    }
    else {
        "Failed to list Intune policies for policy type '$PolicyType'. $($_.Exception.Message)"
    }

    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

#Requires -Version 7.2
<#
.SYNOPSIS
Gets Microsoft Sentinel incidents from a workspace.

.DESCRIPTION
Retrieves one or more Microsoft Sentinel incidents through the workspace-scoped
Microsoft.SecurityInsights ARM provider. When IncidentId is omitted, the script
enumerates incidents across all available pages. When Status is provided, results are
filtered client-side against the incident properties.status value.

.PARAMETER IncidentId
Optional Sentinel incident resource name. When provided, only the specified incident
is returned.

.PARAMETER Status
Optional incident status filter such as New, Active, or Closed.

.PARAMETER SubscriptionId
The Azure subscription ID that contains the Sentinel workspace.

.PARAMETER ResourceGroupName
The Azure resource group name that contains the Sentinel workspace.

.PARAMETER WorkspaceName
The Log Analytics workspace name hosting Microsoft Sentinel.

.PARAMETER AuthContext
An authentication context hashtable returned by the project's authentication helpers.

.EXAMPLE
./Get-SentinelIncident.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -Status 'Active' `
    -AuthContext $authContext

.OUTPUTS
System.Object
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Status,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceName,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$invokeSentinelArmRequestPath = Join-Path $PSScriptRoot 'Invoke-SentinelArmRequest.ps1'

if (-not (Test-Path -Path $invokeSentinelArmRequestPath -PathType Leaf)) {
    throw "Required script not found: $invokeSentinelArmRequestPath"
}

function Invoke-SentinelIncidentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri
    )

    return & $invokeSentinelArmRequestPath `
        -Uri $RequestUri `
        -Method 'GET' `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -WorkspaceName $WorkspaceName `
        -AuthContext $AuthContext
}

function Filter-IncidentsByStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Incidents,

        [Parameter(Mandatory)]
        [string]$DesiredStatus
    )

    return @(
        $Incidents | Where-Object {
            $_.properties -and
            $_.properties.status -and
            $_.properties.status -eq $DesiredStatus
        }
    )
}

try {
    if ($PSBoundParameters.ContainsKey('IncidentId')) {
        $incident = Invoke-SentinelIncidentRequest -RequestUri "/incidents/$IncidentId"

        if ($PSBoundParameters.ContainsKey('Status') -and $incident.properties.status -ne $Status) {
            return @()
        }

        return $incident
    }

    $incidents = [System.Collections.Generic.List[object]]::new()
    $response = Invoke-SentinelIncidentRequest -RequestUri '/incidents'

    foreach ($incident in @($response.value)) {
        $incidents.Add($incident)
    }

    $nextLink = $response.nextLink
    while ($nextLink) {
        $page = Invoke-SentinelIncidentRequest -RequestUri $nextLink
        foreach ($incident in @($page.value)) {
            $incidents.Add($incident)
        }

        $nextLink = $page.nextLink
    }

    if ($PSBoundParameters.ContainsKey('Status')) {
        return Filter-IncidentsByStatus -Incidents $incidents.ToArray() -DesiredStatus $Status
    }

    return $incidents
}
catch {
    throw "Failed to retrieve Sentinel incident data from workspace '$WorkspaceName'. $($_.Exception.Message)"
}

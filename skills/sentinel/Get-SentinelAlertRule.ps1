#Requires -Version 7.2
<#
.SYNOPSIS
Gets Microsoft Sentinel analytic rules from a workspace.

.DESCRIPTION
Retrieves one or more Microsoft Sentinel alert rules through the workspace-scoped
Microsoft.SecurityInsights ARM provider. When RuleId is omitted, the script enumerates
alert rules across all available pages.

.PARAMETER RuleId
Optional Sentinel alert rule resource name. When provided, only the specified rule is
returned.

.PARAMETER SubscriptionId
The Azure subscription ID that contains the Sentinel workspace.

.PARAMETER ResourceGroupName
The Azure resource group name that contains the Sentinel workspace.

.PARAMETER WorkspaceName
The Log Analytics workspace name hosting Microsoft Sentinel.

.PARAMETER AuthContext
An authentication context hashtable returned by the project's authentication helpers.

.EXAMPLE
./Get-SentinelAlertRule.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -AuthContext $authContext

.OUTPUTS
System.Object
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RuleId,

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

function Invoke-SentinelAlertRuleRequest {
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

try {
    if ($PSBoundParameters.ContainsKey('RuleId')) {
        return Invoke-SentinelAlertRuleRequest -RequestUri "/alertRules/$RuleId"
    }

    $alertRules = [System.Collections.Generic.List[object]]::new()
    $response = Invoke-SentinelAlertRuleRequest -RequestUri '/alertRules'

    foreach ($alertRule in @($response.value)) {
        $alertRules.Add($alertRule)
    }

    $nextLink = $response.nextLink
    while ($nextLink) {
        $page = Invoke-SentinelAlertRuleRequest -RequestUri $nextLink
        foreach ($alertRule in @($page.value)) {
            $alertRules.Add($alertRule)
        }

        $nextLink = $page.nextLink
    }

    return $alertRules
}
catch {
    throw "Failed to retrieve Sentinel alert rule data from workspace '$WorkspaceName'. $($_.Exception.Message)"
}

#Requires -Version 7.2
<#
.SYNOPSIS
Invokes a Microsoft Sentinel ARM request under a workspace.

.DESCRIPTION
Builds the workspace-scoped Microsoft.SecurityInsights ARM resource path and submits
the request through the shared Invoke-SkillRestMethod helper. The script supports
relative Sentinel resource paths such as /incidents or /alertRules and also tolerates
absolute nextLink URIs returned by Azure Resource Manager pagination.

.PARAMETER Uri
The relative resource path under the Microsoft.SecurityInsights workspace provider,
for example /incidents or /alertRules/{ruleId}. Absolute nextLink URIs are also
accepted for pagination scenarios.

.PARAMETER Method
The HTTP method to use. Defaults to GET.

.PARAMETER Body
Optional request body for write operations.

.PARAMETER ApiVersion
The ARM API version to use. Defaults to 2024-03-01.

.PARAMETER SubscriptionId
The Azure subscription ID that contains the Sentinel workspace.

.PARAMETER ResourceGroupName
The Azure resource group name that contains the Sentinel workspace.

.PARAMETER WorkspaceName
The Log Analytics workspace name hosting Microsoft Sentinel.

.PARAMETER AuthContext
An authentication context hashtable returned by the project's authentication helpers.

.EXAMPLE
./Invoke-SentinelArmRequest.ps1 `
    -Uri '/incidents' `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -AuthContext $authContext

.OUTPUTS
System.Object
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Uri,

    [Parameter()]
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
    [string]$Method = 'GET',

    [Parameter()]
    [AllowNull()]
    [object]$Body,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '2024-03-01',

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

function Resolve-SentinelArmUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$Subscription,

        [Parameter(Mandatory)]
        [string]$ResourceGroup,

        [Parameter(Mandatory)]
        [string]$Workspace,

        [Parameter(Mandatory)]
        [string]$RequestedApiVersion
    )

    if ([System.Uri]::IsWellFormedUriString($RequestUri, [System.UriKind]::Absolute)) {
        if ($RequestUri -match '([?&])api-version=') {
            return $RequestUri
        }

        $separator = if ($RequestUri.Contains('?')) { '&' } else { '?' }
        return "$RequestUri${separator}api-version=$([System.Uri]::EscapeDataString($RequestedApiVersion))"
    }

    $normalizedRelativeUri = if ($RequestUri.StartsWith('/')) {
        $RequestUri
    }
    else {
        "/$RequestUri"
    }

    $workspaceResourcePath = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationalInsights/workspaces/{2}/providers/Microsoft.SecurityInsights' -f `
        $Subscription,
        $ResourceGroup,
        $Workspace

    $fullUri = '{0}{1}{2}' -f $ArmBaseUri.TrimEnd('/'), $workspaceResourcePath, $normalizedRelativeUri
    $separator = if ($normalizedRelativeUri.Contains('?')) { '&' } else { '?' }

    return "$fullUri${separator}api-version=$([System.Uri]::EscapeDataString($RequestedApiVersion))"
}

try {
    $environment = if ($AuthContext.ContainsKey('Environment') -and $AuthContext.Environment) {
        $AuthContext.Environment
    }
    else {
        'AzureCloud'
    }

    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    $resolvedAuthContext = Resolve-AuthContext -AuthContext $AuthContext -Resource "$($endpoints.SentinelArm)/"

    $requestUri = Resolve-SentinelArmUri `
        -RequestUri $Uri `
        -ArmBaseUri $endpoints.SentinelArm `
        -Subscription $SubscriptionId `
        -ResourceGroup $ResourceGroupName `
        -Workspace $WorkspaceName `
        -RequestedApiVersion $ApiVersion

    return Invoke-SkillRestMethod -Uri $requestUri -Method $Method -Body $Body -AuthContext $resolvedAuthContext
}
catch {
    throw "Failed to invoke Sentinel ARM request for workspace '$WorkspaceName' with URI '$Uri'. $($_.Exception.Message)"
}

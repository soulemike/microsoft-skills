#Requires -Version 7.2
<#
.SYNOPSIS
    Creates or reuses a Log Analytics workspace via ARM.

.DESCRIPTION
    Uses Invoke-SkillRestMethod from Common.psm1 against the ARM endpoint to
    create a Log Analytics workspace when it does not already exist. If the
    workspace already exists, the script returns the existing workspace details
    instead of recreating it. After the workspace is available, the script also
    retrieves the primary shared key.

.PARAMETER SubscriptionId
    Azure subscription ID containing the workspace.

.PARAMETER ResourceGroupName
    Resource group containing the workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace.

.PARAMETER Location
    Azure region for the workspace.

.PARAMETER AuthContext
    ARM-capable authentication context returned by the project's auth helpers.

.OUTPUTS
    Hashtable containing workspace metadata including customerId and
    primarySharedKey.

.EXAMPLE
    ./skills/loganalytics/New-LogAnalyticsWorkspace.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Location eastus -AuthContext $armContext
#>
[CmdletBinding()]
param(
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
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$workspaceApiVersion = '2025-02-01'
$sharedKeysApiVersion = '2025-02-01'

function Get-AuthEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ($Context.ContainsKey('Environment') -and -not [string]::IsNullOrWhiteSpace([string]$Context.Environment)) {
        return [string]$Context.Environment
    }

    return 'AzureCloud'
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    if ($InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }

    return $null
}

function Get-HttpStatusCodeFromException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    if ($response.PSObject.Properties['StatusCode']) {
        $statusCode = $response.PSObject.Properties['StatusCode'].Value
        if ($statusCode -is [int]) {
            return $statusCode
        }

        if ($statusCode.PSObject.Properties['value__']) {
            return [int]$statusCode.PSObject.Properties['value__'].Value
        }
    }

    if ($ErrorRecord.Exception.Message -match 'HTTP\s+(\d{3})') {
        return [int]$Matches[1]
    }

    return $null
}

function Resolve-ArmAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $environment = Get-AuthEnvironment -Context $Context
    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    return (Resolve-AuthContext -AuthContext $Context -Resource ('{0}/' -f $endpoints.Arm.TrimEnd('/')))
}

try {
    $resolvedAuthContext = Resolve-ArmAuthContext -Context $AuthContext
    $armEndpoint = (Get-EnvironmentEndpoints -Environment (Get-AuthEnvironment -Context $AuthContext)).Arm.TrimEnd('/')
    $workspaceUri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.OperationalInsights/workspaces/{3}?api-version={4}' -f `
        $armEndpoint,
        [System.Uri]::EscapeDataString($SubscriptionId),
        [System.Uri]::EscapeDataString($ResourceGroupName),
        [System.Uri]::EscapeDataString($WorkspaceName),
        [System.Uri]::EscapeDataString($workspaceApiVersion)

    $workspaceResponse = $null
    $workspaceExists = $false

    try {
        $workspaceResponse = Invoke-SkillRestMethod -Uri $workspaceUri -AuthContext $resolvedAuthContext -Method 'GET'
        $workspaceExists = $true
    }
    catch {
        $statusCode = Get-HttpStatusCodeFromException -ErrorRecord $_
        if ($statusCode -ne 404) {
            throw
        }
    }

    if (-not $workspaceExists) {
        $workspaceBody = @{
            location = $Location
            properties = @{
                sku = @{
                    name = 'PerGB2018'
                }
            }
        }

        $null = Invoke-SkillRestMethod -Uri $workspaceUri -AuthContext $resolvedAuthContext -Method 'PUT' -Body $workspaceBody
        $workspaceResponse = Invoke-SkillRestMethod -Uri $workspaceUri -AuthContext $resolvedAuthContext -Method 'GET'
    }

    $workspaceId = Get-ObjectPropertyValue -InputObject $workspaceResponse -Name 'id'
    $workspaceNameResolved = Get-ObjectPropertyValue -InputObject $workspaceResponse -Name 'name'
    $workspaceLocation = Get-ObjectPropertyValue -InputObject $workspaceResponse -Name 'location'
    $workspaceProperties = Get-ObjectPropertyValue -InputObject $workspaceResponse -Name 'properties'
    $customerId = Get-ObjectPropertyValue -InputObject $workspaceProperties -Name 'customerId'
    $provisioningState = Get-ObjectPropertyValue -InputObject $workspaceProperties -Name 'provisioningState'

    $sharedKeysUri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.OperationalInsights/workspaces/{3}/sharedKeys?api-version={4}' -f `
        $armEndpoint,
        [System.Uri]::EscapeDataString($SubscriptionId),
        [System.Uri]::EscapeDataString($ResourceGroupName),
        [System.Uri]::EscapeDataString($WorkspaceName),
        [System.Uri]::EscapeDataString($sharedKeysApiVersion)

    $sharedKeysResponse = Invoke-SkillRestMethod -Uri $sharedKeysUri -AuthContext $resolvedAuthContext -Method 'POST'
    $primarySharedKey = Get-ObjectPropertyValue -InputObject $sharedKeysResponse -Name 'primarySharedKey'

    return [ordered]@{
        WorkspaceName = $workspaceNameResolved
        ResourceId = $workspaceId
        Location = $workspaceLocation
        CustomerId = $customerId
        PrimarySharedKey = $primarySharedKey
        ProvisioningState = $provisioningState
        Exists = $workspaceExists
    }
}
catch {
    $message = "Failed to create or retrieve Log Analytics workspace '$WorkspaceName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

#Requires -Version 7.2
<#
.SYNOPSIS
    Creates or updates a Log Analytics custom table via ARM.

.DESCRIPTION
    Uses the Microsoft.OperationalInsights/workspaces/tables ARM provider to
    create or update a custom table schema in a Log Analytics workspace.

.PARAMETER SubscriptionId
    Azure subscription ID containing the workspace.

.PARAMETER ResourceGroupName
    Resource group containing the workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.PARAMETER TableName
    Custom table name, typically ending in _CL.

.PARAMETER SchemaColumns
    Array of hashtables containing name, type, and description keys.

.PARAMETER AuthContext
    ARM-capable authentication context.

.OUTPUTS
    Hashtable describing the resulting table resource.

.EXAMPLE
    ./skills/loganalytics/New-LogAnalyticsCustomTable.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -TableName 'CustomAppEvents_CL' -SchemaColumns $columns -AuthContext $armContext
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
    [string]$TableName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [hashtable[]]$SchemaColumns,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$tableApiVersion = '2025-02-01'

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

try {
    $resolvedAuthContext = Resolve-ArmAuthContext -Context $AuthContext
    $armEndpoint = (Get-EnvironmentEndpoints -Environment (Get-AuthEnvironment -Context $AuthContext)).Arm.TrimEnd('/')

    $columns = [System.Collections.Generic.List[object]]::new()
    foreach ($column in $SchemaColumns) {
        if (-not $column.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$column.name)) {
            throw 'Each SchemaColumns entry must include a non-empty name value.'
        }

        if (-not $column.ContainsKey('type') -or [string]::IsNullOrWhiteSpace([string]$column.type)) {
            throw "Schema column '$($column.name)' must include a non-empty type value."
        }

        $columns.Add([ordered]@{
            name = [string]$column.name
            type = [string]$column.type
            description = if ($column.ContainsKey('description') -and -not [string]::IsNullOrWhiteSpace([string]$column.description)) { [string]$column.description } else { '' }
        })
    }

    $tableUri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.OperationalInsights/workspaces/{3}/tables/{4}?api-version={5}' -f `
        $armEndpoint,
        [System.Uri]::EscapeDataString($SubscriptionId),
        [System.Uri]::EscapeDataString($ResourceGroupName),
        [System.Uri]::EscapeDataString($WorkspaceName),
        [System.Uri]::EscapeDataString($TableName),
        [System.Uri]::EscapeDataString($tableApiVersion)

    $tableBody = @{
        properties = @{
            schema = @{
                name = $TableName
                columns = @($columns)
            }
        }
    }

    $null = Invoke-SkillRestMethod -Uri $tableUri -AuthContext $resolvedAuthContext -Method 'PUT' -Body $tableBody
    $tableResponse = Invoke-SkillRestMethod -Uri $tableUri -AuthContext $resolvedAuthContext -Method 'GET'

    $properties = Get-ObjectPropertyValue -InputObject $tableResponse -Name 'properties'

    return [ordered]@{
        TableName = Get-ObjectPropertyValue -InputObject $tableResponse -Name 'name'
        ResourceId = Get-ObjectPropertyValue -InputObject $tableResponse -Name 'id'
        ProvisioningState = Get-ObjectPropertyValue -InputObject $properties -Name 'provisioningState'
        Schema = Get-ObjectPropertyValue -InputObject $properties -Name 'schema'
    }
}
catch {
    $message = "Failed to create or update Log Analytics custom table '$TableName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

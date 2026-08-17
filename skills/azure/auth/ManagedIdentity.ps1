#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes an Azure ARM context using managed identity.

.DESCRIPTION
    Thin wrapper around Connect-AzureApi.ps1 for system-assigned or
    user-assigned managed identity authentication against Azure Resource
    Manager.

.PARAMETER ClientId
    Optional user-assigned managed identity client ID.

.PARAMETER TenantId
    Optional tenant ID to include on the returned context when known.

.PARAMETER Environment
    Azure cloud environment.

.PARAMETER SubscriptionId
    Optional Azure subscription ID to attach to the returned context.

.PARAMETER AuthContext
    Optional pre-resolved authentication context to enrich.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/azure/auth/ManagedIdentity.ps1 -Environment AzureCloud

.EXAMPLE
    ./skills/azure/auth/ManagedIdentity.ps1 -ClientId $userAssignedIdentityClientId -Environment AzureCloud -SubscriptionId $subscriptionId
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [Alias('AzureEnvironment')]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [hashtable]$AuthContext
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot '..' '..' 'Common.psm1'
Import-Module $commonModulePath -Force

$connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-AzureApi.ps1'

try {
    $connectParams = @{
        AuthenticationType = 'ManagedIdentity'
        UseManagedIdentity = $true
        Environment = $Environment
    }

    if ($ClientId) {
        $connectParams.ClientId = $ClientId
    }

    if ($TenantId) {
        $connectParams.TenantId = $TenantId
    }

    if ($SubscriptionId) {
        $connectParams.SubscriptionId = $SubscriptionId
    }

    if ($AuthContext) {
        $connectParams.AuthContext = $AuthContext
    }

    return & $connectScriptPath @connectParams
}
catch {
    $message = "Failed to establish Azure ARM managed identity context. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

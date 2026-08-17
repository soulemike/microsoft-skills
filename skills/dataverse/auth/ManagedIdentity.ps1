#Requires -Version 7.2
<#
.SYNOPSIS
Connects to Dataverse by using managed identity.

.DESCRIPTION
Thin wrapper around Connect-DataverseApi.ps1 that fixes AuthenticationType to
ManagedIdentity. Use -ClientId for a user-assigned managed identity when needed.

.EXAMPLE
./ManagedIdentity.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter()][string]$TenantId,
    [Parameter()][string]$ClientId,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-DataverseApi.ps1'
    $parameters = @{
        AuthenticationType = 'ManagedIdentity'
        UseManagedIdentity = $true
        EnvironmentUrl = $EnvironmentUrl
        Environment = $Environment
    }

    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $parameters.TenantId = $TenantId
    }
    if ($PSBoundParameters.ContainsKey('ClientId')) {
        $parameters.ClientId = $ClientId
    }

    return & $connectScriptPath @parameters
}
catch {
    $message = "Failed to connect to Dataverse by using managed identity. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

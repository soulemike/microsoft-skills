#Requires -Version 7.2
<#
.SYNOPSIS
Connects to Dataverse by using client credentials.

.DESCRIPTION
Thin wrapper around Connect-DataverseApi.ps1 that fixes AuthenticationType to
ClientCredentials.

.EXAMPLE
./ClientCredentials.ps1 -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -ClientSecret $secret -EnvironmentUrl https://contoso.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][securestring]$ClientSecret,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-DataverseApi.ps1'
    return & $connectScriptPath -AuthenticationType 'ClientCredentials' -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -EnvironmentUrl $EnvironmentUrl -Environment $Environment
}
catch {
    $message = "Failed to connect to Dataverse by using client credentials. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

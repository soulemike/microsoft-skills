#Requires -Version 7.2
<#
.SYNOPSIS
Connects to Dataverse by using federated credentials.

.DESCRIPTION
Thin wrapper around Connect-DataverseApi.ps1 that fixes AuthenticationType to
Federated.

.EXAMPLE
./FederatedCredentials.ps1 -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -FederatedToken $oidcToken -EnvironmentUrl https://contoso.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$FederatedToken,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-DataverseApi.ps1'
    return & $connectScriptPath -AuthenticationType 'Federated' -TenantId $TenantId -ClientId $ClientId -FederatedToken $FederatedToken -EnvironmentUrl $EnvironmentUrl -Environment $Environment
}
catch {
    $message = "Failed to connect to Dataverse by using federated credentials. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

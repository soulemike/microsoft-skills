#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Log Analytics token using federated credentials.

.DESCRIPTION
    Thin wrapper around Exchange-FederatedToken in Common.psm1 that resolves the
    Log Analytics token audience and request endpoint for the selected Azure
    environment.

.PARAMETER TenantId
    Entra ID tenant identifier.

.PARAMETER ClientId
    Application (client) identifier.

.PARAMETER FederatedToken
    OIDC token issued by the trusted workload identity provider.

.PARAMETER Environment
    Azure environment used to resolve the Log Analytics endpoints.

.OUTPUTS
    Hashtable representing a Log Analytics authentication context.

.EXAMPLE
    ./skills/loganalytics/auth/FederatedCredentials.ps1 -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -FederatedToken $env:AZURE_FEDERATED_TOKEN -Environment AzureCloud
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$FederatedToken,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'Common.psm1') -Force -ErrorAction Stop

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $tokenAudience = $endpoints.LogAnalyticsTokenAudience
    $baseUri = $endpoints.LogAnalytics.TrimEnd('/')
    $tokenResponse = Exchange-FederatedToken -OidcToken $FederatedToken -Resource $tokenAudience -TenantId $TenantId -ClientId $ClientId

    return @{
        Method = 'Federated'
        Token = $tokenResponse.Token
        ExpiresOn = $tokenResponse.ExpiresOn
        TenantId = $TenantId
        ClientId = $ClientId
        Environment = $Environment
        BaseUri = $baseUri
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Log Analytics token using federated credentials. {0}' -f $_.Exception.Message, $_.Exception)
}

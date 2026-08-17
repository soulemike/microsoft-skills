#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Log Analytics token using client credentials.

.DESCRIPTION
    Thin wrapper around Get-ClientCredentialToken in Common.psm1 that resolves
    the Log Analytics token audience and request endpoint for the selected Azure
    environment. This script emits the mandatory warning required for client
    secret authentication before requesting the token.

.PARAMETER TenantId
    Entra ID tenant identifier.

.PARAMETER ClientId
    Application (client) identifier.

.PARAMETER ClientSecret
    Secure client secret.

.PARAMETER Environment
    Azure environment used to resolve the Log Analytics endpoints.

.OUTPUTS
    Hashtable representing a Log Analytics authentication context.

.EXAMPLE
    ./skills/loganalytics/auth/ClientCredentials.ps1 -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -ClientSecret $secret -Environment AzureCloud
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [SecureString]$ClientSecret,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'Common.psm1') -Force -ErrorAction Stop

Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $tokenAudience = $endpoints.LogAnalyticsTokenAudience
    $baseUri = $endpoints.LogAnalytics.TrimEnd('/')
    $tokenResponse = Get-ClientCredentialToken -Resource $tokenAudience -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    return @{
        Method = 'ClientCredentials'
        Token = $tokenResponse.Token
        ExpiresOn = $tokenResponse.ExpiresOn
        TenantId = $TenantId
        ClientId = $ClientId
        Environment = $Environment
        BaseUri = $baseUri
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Log Analytics token using client credentials. {0}' -f $_.Exception.Message, $_.Exception)
}

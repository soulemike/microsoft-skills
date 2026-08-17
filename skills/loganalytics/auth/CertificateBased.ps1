#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Log Analytics token using certificate-based authentication.

.DESCRIPTION
    Thin wrapper around Get-CertificateToken in Common.psm1 that resolves the
    Log Analytics token audience and request endpoint for the selected Azure
    environment.

.PARAMETER TenantId
    Entra ID tenant identifier.

.PARAMETER ClientId
    Application (client) identifier.

.PARAMETER CertificatePath
    Path to the certificate file.

.PARAMETER Environment
    Azure environment used to resolve the Log Analytics endpoints.

.OUTPUTS
    Hashtable representing a Log Analytics authentication context.

.EXAMPLE
    ./skills/loganalytics/auth/CertificateBased.ps1 -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -CertificatePath '/secure/certs/loganalytics.pfx' -Environment AzureCloud
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$CertificatePath,

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
    $tokenResponse = Get-CertificateToken -Resource $tokenAudience -TenantId $TenantId -ClientId $ClientId -CertificatePath $CertificatePath

    return @{
        Method = 'Certificate'
        Token = $tokenResponse.Token
        ExpiresOn = $tokenResponse.ExpiresOn
        TenantId = $TenantId
        ClientId = $ClientId
        Environment = $Environment
        BaseUri = $baseUri
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Log Analytics token using certificate-based authentication. {0}' -f $_.Exception.Message, $_.Exception)
}

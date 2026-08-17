#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Log Analytics token using managed identity.

.DESCRIPTION
    Thin wrapper around Get-ManagedIdentityToken in Common.psm1 that resolves
    the Log Analytics token audience and request endpoint for the selected Azure
    environment.

.PARAMETER Environment
    Azure environment used to resolve the Log Analytics endpoints.

.OUTPUTS
    Hashtable representing a Log Analytics authentication context.

.EXAMPLE
    ./skills/loganalytics/auth/ManagedIdentity.ps1 -Environment AzureCloud
#>
[CmdletBinding()]
param(
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
    $token = Get-ManagedIdentityToken -Resource $tokenAudience

    if (-not $token) {
        throw 'Managed identity token acquisition returned no token.'
    }

    return @{
        Method = 'ManagedIdentity'
        Token = $token
        ExpiresOn = $null
        Environment = $Environment
        BaseUri = $baseUri
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Log Analytics token using managed identity. {0}' -f $_.Exception.Message, $_.Exception)
}

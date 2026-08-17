#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Microsoft Graph token using client credentials.

.DESCRIPTION
    Thin wrapper around Get-ClientCredentialToken in Common.psm1 that resolves
    the Graph resource endpoint for the selected Azure environment. This script
    emits the mandatory warning required for client secret authentication before
    requesting the token.

.PARAMETER TenantId
    Entra ID tenant identifier.

.PARAMETER ClientId
    Application (client) identifier.

.PARAMETER ClientSecret
    Secure client secret.

.PARAMETER Environment
    Azure environment used to resolve the Graph resource endpoint.

.OUTPUTS
    Hashtable representing a Graph authentication context.

.EXAMPLE
    ./skills/graph/auth/ClientCredentials.ps1 -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -ClientSecret $secret -Environment AzureCloud
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

$commonModulePath = Join-Path -Path (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..') -ChildPath '..') -ChildPath 'Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $graphEndpoint = $endpoints.Graph.TrimEnd('/')
    $tokenResponse = Get-ClientCredentialToken -Resource $graphEndpoint -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    return @{
        Method       = 'ClientCredentials'
        Token        = $tokenResponse.Token
        ExpiresOn    = $tokenResponse.ExpiresOn
        TenantId     = $TenantId
        ClientId     = $ClientId
        Environment  = $Environment
        GraphEndpoint = $graphEndpoint
        BaseUri      = '{0}/v1.0' -f $graphEndpoint
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Microsoft Graph token using client credentials. {0}' -f $_.Exception.Message, $_.Exception)
}

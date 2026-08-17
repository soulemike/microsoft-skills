#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Microsoft Graph token using federated credentials.

.DESCRIPTION
    Thin wrapper around Exchange-FederatedToken in Common.psm1 that resolves
    the Graph resource endpoint for the selected Azure environment.

.PARAMETER TenantId
    Entra ID tenant identifier.

.PARAMETER ClientId
    Application (client) identifier.

.PARAMETER FederatedToken
    OIDC token issued by the trusted workload identity provider.

.PARAMETER Environment
    Azure environment used to resolve the Graph resource endpoint.

.OUTPUTS
    Hashtable representing a Graph authentication context.

.EXAMPLE
    ./skills/graph/auth/FederatedCredentials.ps1 -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -FederatedToken $env:AZURE_FEDERATED_TOKEN -Environment AzureCloud
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

$commonModulePath = Join-Path -Path (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..') -ChildPath '..') -ChildPath 'Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $graphEndpoint = $endpoints.Graph.TrimEnd('/')
    $tokenResponse = Exchange-FederatedToken -OidcToken $FederatedToken -Resource $graphEndpoint -TenantId $TenantId -ClientId $ClientId

    return @{
        Method       = 'Federated'
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
    throw [System.InvalidOperationException]::new('Failed to acquire a Microsoft Graph token using federated credentials. {0}' -f $_.Exception.Message, $_.Exception)
}

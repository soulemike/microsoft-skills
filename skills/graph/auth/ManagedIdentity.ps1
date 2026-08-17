#Requires -Version 7.2
<#
.SYNOPSIS
    Acquires a Microsoft Graph token using managed identity.

.DESCRIPTION
    Thin wrapper around Get-ManagedIdentityToken in Common.psm1 that resolves
    the Graph resource endpoint for the selected Azure environment and returns a
    Graph-oriented authentication context.

.PARAMETER Environment
    Azure environment used to resolve the Graph resource endpoint.

.OUTPUTS
    Hashtable representing a Graph authentication context.

.EXAMPLE
    ./skills/graph/auth/ManagedIdentity.ps1 -Environment AzureCloud
#>
[CmdletBinding()]
param(
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
    $token = Get-ManagedIdentityToken -Resource $graphEndpoint

    if (-not $token) {
        throw 'Managed identity token acquisition returned no token.'
    }

    return @{
        Method       = 'ManagedIdentity'
        Token        = $token
        ExpiresOn    = $null
        Environment  = $Environment
        GraphEndpoint = $graphEndpoint
        BaseUri      = '{0}/v1.0' -f $graphEndpoint
    }
}
catch {
    throw [System.InvalidOperationException]::new('Failed to acquire a Microsoft Graph token using managed identity. {0}' -f $_.Exception.Message, $_.Exception)
}

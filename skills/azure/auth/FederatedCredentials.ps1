#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes an Azure ARM context using federated credentials.

.DESCRIPTION
    Thin wrapper around Connect-AzureApi.ps1 for OIDC-based workload identity
    authentication against Azure Resource Manager.

.PARAMETER TenantId
    Microsoft Entra tenant ID.

.PARAMETER ClientId
    Application (client) ID configured with a federated identity credential.

.PARAMETER FederatedToken
    OIDC token issued by the CI/CD or workload identity provider.

.PARAMETER Environment
    Azure cloud environment.

.PARAMETER SubscriptionId
    Optional Azure subscription ID to attach to the returned context.

.PARAMETER AuthContext
    Optional pre-resolved authentication context to enrich.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/azure/auth/FederatedCredentials.ps1 -TenantId $tenantId -ClientId $clientId -FederatedToken $oidcToken -Environment AzureCloud
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$FederatedToken,

    [Parameter(Mandatory)]
    [Alias('AzureEnvironment')]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [hashtable]$AuthContext
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot '..' '..' 'Common.psm1'
Import-Module $commonModulePath -Force

$connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-AzureApi.ps1'

try {
    $connectParams = @{
        AuthenticationType = 'Federated'
        TenantId = $TenantId
        ClientId = $ClientId
        FederatedToken = $FederatedToken
        Environment = $Environment
    }

    if ($SubscriptionId) {
        $connectParams.SubscriptionId = $SubscriptionId
    }

    if ($AuthContext) {
        $connectParams.AuthContext = $AuthContext
    }

    return & $connectScriptPath @connectParams
}
catch {
    $message = "Failed to establish Azure ARM federated credential context. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

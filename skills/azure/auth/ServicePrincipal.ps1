#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes an Azure ARM context using a service principal.

.DESCRIPTION
    Thin wrapper around Connect-AzureApi.ps1 for service principal
    authentication. Supports certificate-based authentication and
    client credentials with a secure client secret.

.PARAMETER TenantId
    Microsoft Entra tenant ID.

.PARAMETER ClientId
    Service principal application (client) ID.

.PARAMETER ClientSecret
    Secure client secret for client credential authentication.

.PARAMETER CertificatePath
    Path to the PFX certificate used for certificate-based authentication.

.PARAMETER Environment
    Azure cloud environment.

.PARAMETER SubscriptionId
    Optional Azure subscription ID to attach to the returned context.

.PARAMETER AuthContext
    Optional pre-resolved authentication context to enrich.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/azure/auth/ServicePrincipal.ps1 -TenantId $tenantId -ClientId $clientId -CertificatePath '/secure/certs/automation.pfx' -Environment AzureCloud

.EXAMPLE
    ./skills/azure/auth/ServicePrincipal.ps1 -TenantId $tenantId -ClientId $clientId -ClientSecret $secret -Environment AzureCloud
#>
[CmdletBinding(DefaultParameterSetName = 'Certificate')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory, ParameterSetName = 'ClientSecret')]
    [SecureString]$ClientSecret,

    [Parameter(Mandatory, ParameterSetName = 'Certificate')]
    [string]$CertificatePath,

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
        TenantId = $TenantId
        ClientId = $ClientId
        Environment = $Environment
    }

    if ($SubscriptionId) {
        $connectParams.SubscriptionId = $SubscriptionId
    }

    if ($AuthContext) {
        $connectParams.AuthContext = $AuthContext
    }

    switch ($PSCmdlet.ParameterSetName) {
        'Certificate' {
            $connectParams.AuthenticationType = 'Certificate'
            $connectParams.CertificatePath = $CertificatePath
        }
        'ClientSecret' {
            $connectParams.AuthenticationType = 'ClientCredentials'
            $connectParams.ClientSecret = $ClientSecret
        }
        default {
            throw "Unsupported parameter set '$($PSCmdlet.ParameterSetName)'."
        }
    }

    return & $connectScriptPath @connectParams
}
catch {
    $message = "Failed to establish Azure ARM service principal context. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

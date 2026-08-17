#Requires -Version 7.2
<#
.SYNOPSIS
Connects to Dataverse by using certificate-based authentication.

.DESCRIPTION
Thin wrapper around Connect-DataverseApi.ps1 that fixes AuthenticationType to
Certificate.

.EXAMPLE
./CertificateBased.ps1 -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -CertificatePath /secure/certs/app.pfx -EnvironmentUrl https://contoso.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter()][string]$CertificateThumbprint,
    [Parameter()][string]$CertificatePath,
    [Parameter()][securestring]$CertificatePassword,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $connectScriptPath = Join-Path $PSScriptRoot '..' 'Connect-DataverseApi.ps1'
    $parameters = @{
        AuthenticationType = 'Certificate'
        TenantId = $TenantId
        ClientId = $ClientId
        EnvironmentUrl = $EnvironmentUrl
        Environment = $Environment
    }

    if ($PSBoundParameters.ContainsKey('CertificateThumbprint')) {
        $parameters.CertificateThumbprint = $CertificateThumbprint
    }
    if ($PSBoundParameters.ContainsKey('CertificatePath')) {
        $parameters.CertificatePath = $CertificatePath
    }
    if ($PSBoundParameters.ContainsKey('CertificatePassword')) {
        $parameters.CertificatePassword = $CertificatePassword
    }

    return & $connectScriptPath @parameters
}
catch {
    $message = "Failed to connect to Dataverse by using certificate-based authentication. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

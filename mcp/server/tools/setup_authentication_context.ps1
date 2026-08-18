#Requires -Version 7.2
<#
.SYNOPSIS
Wraps prerequisites/Setup-AuthenticationContext.ps1 and stores the returned auth context.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Resource = 'https://management.azure.com/',

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$ClientSecret,

    [Parameter()]
    [string]$CertificatePath,

    [Parameter()]
    [string]$FederatedToken,

    [Parameter()]
    [bool]$SuppressWarning = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'MicrosoftCloudApiSkills.Mcp.psm1') -ErrorAction Stop

$parameters = @{
    Resource = $Resource
}

if ($PSBoundParameters.ContainsKey('TenantId')) { $parameters.TenantId = $TenantId }
if ($PSBoundParameters.ContainsKey('ClientId')) { $parameters.ClientId = $ClientId }
if ($PSBoundParameters.ContainsKey('ClientSecret')) { $parameters.ClientSecret = $ClientSecret }
if ($PSBoundParameters.ContainsKey('CertificatePath')) { $parameters.CertificatePath = $CertificatePath }
if ($PSBoundParameters.ContainsKey('FederatedToken')) { $parameters.FederatedToken = $FederatedToken }
if ($SuppressWarning) { $parameters.SuppressWarning = $true }

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'prerequisites/Setup-AuthenticationContext.ps1' -Parameters $parameters
$record = Save-McpContextRecord -ContextType 'auth' -Payload @{ AuthContext = $invocation.Result }

Format-McpToolResult -Data $record -Warnings $invocation.Warnings -Messages $invocation.Messages

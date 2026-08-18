#Requires -Version 7.2
<#
.SYNOPSIS
Creates a Microsoft Graph authentication context and stores it for later MCP tool calls.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('ManagedIdentity', 'Federated', 'Certificate', 'ClientCredentials')]
    [string]$AuthenticationType,

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
    [bool]$UseManagedIdentity = $false,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [Parameter()]
    [string]$ContextId,

    [Parameter()]
    [AllowNull()]
    [object]$AuthContext,

    [Parameter()]
    [string]$Prefix,

    [Parameter()]
    [string]$Profile,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'MicrosoftCloudApiSkills.Mcp.psm1') -ErrorAction Stop

$parameters = @{ Environment = $Environment }
if ($PSBoundParameters.ContainsKey('AuthenticationType')) { $parameters.AuthenticationType = $AuthenticationType }
if ($PSBoundParameters.ContainsKey('TenantId')) { $parameters.TenantId = $TenantId }
if ($PSBoundParameters.ContainsKey('ClientId')) { $parameters.ClientId = $ClientId }
if ($PSBoundParameters.ContainsKey('ClientSecret')) { $parameters.ClientSecret = ConvertTo-McpSecureString -Value $ClientSecret }
if ($PSBoundParameters.ContainsKey('CertificatePath')) { $parameters.CertificatePath = $CertificatePath }
if ($PSBoundParameters.ContainsKey('FederatedToken')) { $parameters.FederatedToken = $FederatedToken }
if ($UseManagedIdentity) { $parameters.UseManagedIdentity = $true }
if ($PSBoundParameters.ContainsKey('Prefix')) { $parameters.Prefix = $Prefix }
if ($PSBoundParameters.ContainsKey('Profile')) { $parameters.Profile = $Profile }
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $parameters.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('ContextId') -or $PSBoundParameters.ContainsKey('AuthContext')) {
    $parameters.AuthContext = Resolve-McpContext -ContextId $ContextId -AuthContext $AuthContext -Purpose 'Graph'
}

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/graph/Connect-GraphApi.ps1' -Parameters $parameters
$record = Save-McpContextRecord -ContextType 'graph' -Payload @{ AuthContext = $invocation.Result }

Format-McpToolResult -Data $record -Warnings $invocation.Warnings -Messages $invocation.Messages

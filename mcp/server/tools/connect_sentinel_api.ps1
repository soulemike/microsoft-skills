#Requires -Version 7.2
<#
.SYNOPSIS
Creates both Sentinel ARM and Log Analytics auth contexts and stores them as one MCP session bundle.
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
    [string]$SubscriptionId,

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

$azureParameters = @{ Environment = $Environment }
$logAnalyticsParameters = @{ Environment = $Environment }

foreach ($name in @('AuthenticationType', 'TenantId', 'ClientId', 'CertificatePath', 'FederatedToken', 'Prefix', 'Profile', 'ConfigPath')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $value = Get-Variable -Name $name -ValueOnly
        $azureParameters[$name] = $value
        $logAnalyticsParameters[$name] = $value
    }
}

if ($PSBoundParameters.ContainsKey('ClientSecret')) {
    $secureClientSecret = ConvertTo-McpSecureString -Value $ClientSecret
    $azureParameters.ClientSecret = $secureClientSecret
    $logAnalyticsParameters.ClientSecret = $secureClientSecret
}

if ($UseManagedIdentity) {
    $azureParameters.UseManagedIdentity = $true
    $logAnalyticsParameters.UseManagedIdentity = $true
}

if ($PSBoundParameters.ContainsKey('SubscriptionId')) {
    $azureParameters.SubscriptionId = $SubscriptionId
}

$azureInvocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/azure/Connect-AzureApi.ps1' -Parameters $azureParameters
$logAnalyticsInvocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/loganalytics/Connect-LogAnalyticsApi.ps1' -Parameters $logAnalyticsParameters

$record = Save-McpContextRecord -ContextType 'sentinel' -Payload @{
    SentinelArmContext = $azureInvocation.Result
    LogAnalyticsContext = $logAnalyticsInvocation.Result
}

Format-McpToolResult -Data $record -Warnings ($azureInvocation.Warnings + $logAnalyticsInvocation.Warnings) -Messages ($azureInvocation.Messages + $logAnalyticsInvocation.Messages)

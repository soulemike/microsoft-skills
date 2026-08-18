#Requires -Version 7.2
<#
.SYNOPSIS
Gets Intune managed devices with a stored or supplied Graph/Intune auth context.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$DeviceId,

    [Parameter()]
    [string[]]$Select,

    [Parameter()]
    [string]$ContextId,

    [Parameter()]
    [AllowNull()]
    [object]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'MicrosoftCloudApiSkills.Mcp.psm1') -ErrorAction Stop

$parameters = @{
    AuthContext = Resolve-McpContext -ContextId $ContextId -AuthContext $AuthContext -Purpose 'Intune'
}

if ($PSBoundParameters.ContainsKey('DeviceId')) { $parameters.DeviceId = $DeviceId }
if ($PSBoundParameters.ContainsKey('Select')) { $parameters.Select = $Select }

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/intune/Get-IntuneDevice.ps1' -Parameters $parameters
Format-McpToolResult -Data $invocation.Result -Warnings $invocation.Warnings -Messages $invocation.Messages

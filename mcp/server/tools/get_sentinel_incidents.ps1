#Requires -Version 7.2
<#
.SYNOPSIS
Lists Microsoft Sentinel incidents with a stored or supplied Sentinel ARM auth context.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$IncidentId,

    [Parameter()]
    [string]$Status,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

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
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    WorkspaceName = $WorkspaceName
    AuthContext = Resolve-McpContext -ContextId $ContextId -AuthContext $AuthContext -Purpose 'SentinelArm'
}

if ($PSBoundParameters.ContainsKey('IncidentId')) { $parameters.IncidentId = $IncidentId }
if ($PSBoundParameters.ContainsKey('Status')) { $parameters.Status = $Status }

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/sentinel/Get-SentinelIncident.ps1' -Parameters $parameters
Format-McpToolResult -Data $invocation.Result -Warnings $invocation.Warnings -Messages $invocation.Messages

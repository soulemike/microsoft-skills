#Requires -Version 7.2
<#
.SYNOPSIS
Runs a Log Analytics KQL query with a stored or supplied auth context.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [Parameter(Mandatory)]
    [string]$Query,

    [Parameter()]
    [string]$Timespan,

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
    WorkspaceId = $WorkspaceId
    Query = $Query
    AuthContext = Resolve-McpContext -ContextId $ContextId -AuthContext $AuthContext -Purpose 'LogAnalytics'
}

if ($PSBoundParameters.ContainsKey('Timespan')) { $parameters.Timespan = $Timespan }

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/loganalytics/Invoke-LogAnalyticsKqlQuery.ps1' -Parameters $parameters
Format-McpToolResult -Data $invocation.Result -Warnings $invocation.Warnings -Messages $invocation.Messages

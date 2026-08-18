#Requires -Version 7.2
<#
.SYNOPSIS
Invokes an Azure ARM request with a stored or supplied auth context.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Uri,

    [Parameter()]
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')]
    [string]$Method = 'GET',

    [Parameter()]
    [AllowNull()]
    [object]$Body,

    [Parameter()]
    [string]$ContentType = 'application/json',

    [Parameter()]
    [string]$ApiVersion,

    [Parameter()]
    [string]$ContextId,

    [Parameter()]
    [AllowNull()]
    [object]$AuthContext,

    [Parameter()]
    [bool]$Paginate = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'MicrosoftCloudApiSkills.Mcp.psm1') -ErrorAction Stop

$parameters = @{
    Uri = $Uri
    Method = $Method
    ContentType = $ContentType
    AuthContext = Resolve-McpContext -ContextId $ContextId -AuthContext $AuthContext -Purpose 'Azure'
}

if ($PSBoundParameters.ContainsKey('Body')) { $parameters.Body = $Body }
if ($PSBoundParameters.ContainsKey('ApiVersion')) { $parameters.ApiVersion = $ApiVersion }
if ($Paginate) { $parameters.Paginate = $true }

$invocation = Invoke-MicrosoftCloudApiSkillScript -RelativePath 'skills/azure/Invoke-AzureRestMethod.ps1' -Parameters $parameters
Format-McpToolResult -Data $invocation.Result -Warnings $invocation.Warnings -Messages $invocation.Messages

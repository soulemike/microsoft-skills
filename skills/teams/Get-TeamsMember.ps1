#Requires -Version 7.2
<#
.SYNOPSIS
    Gets Microsoft Teams members for a team or channel.

.DESCRIPTION
    Retrieves Microsoft Teams membership information through Microsoft Graph.
    When ChannelId is omitted, the script lists team members from
    /teams/{team-id}/members. When ChannelId is supplied, it lists
    channel-specific members from /teams/{team-id}/channels/{channel-id}/members.

    Channel membership is typically applicable to private and shared channels.
    Standard channels inherit team membership, and Microsoft Graph may reject
    channel-member queries for unsupported channel types.

.PARAMETER TeamId
    The Microsoft Teams team identifier.

.PARAMETER ChannelId
    Optional channel identifier for channel-specific member retrieval.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.OUTPUTS
    System.Object[]

.EXAMPLE
    ./skills/teams/Get-TeamsMember.ps1 -TeamId $teamId -AuthContext $context

.EXAMPLE
    ./skills/teams/Get-TeamsMember.ps1 -TeamId $teamId -ChannelId $channelId -AuthContext $context
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TeamId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ChannelId,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$invokeTeamsGraphRequestPath = Join-Path $PSScriptRoot 'Invoke-TeamsGraphRequest.ps1'
if (-not (Test-Path -Path $invokeTeamsGraphRequestPath -PathType Leaf)) {
    throw "Required script not found: $invokeTeamsGraphRequestPath"
}

function ConvertFrom-TeamsCollectionResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response -is [System.Array]) {
        return $Response
    }

    if ($Response -and $Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }

    return @($Response)
}

try {
    $requestUri = if ($PSBoundParameters.ContainsKey('ChannelId')) {
        "/$TeamId/channels/$ChannelId/members"
    }
    else {
        "/$TeamId/members"
    }

    $response = & $invokeTeamsGraphRequestPath -Uri $requestUri -Method 'GET' -AuthContext $AuthContext
    return ConvertFrom-TeamsCollectionResponse -Response $response
}
catch {
    $message = if ($PSBoundParameters.ContainsKey('ChannelId')) {
        "Failed to retrieve members for team '$TeamId' channel '$ChannelId'. $($_.Exception.Message)"
    }
    else {
        "Failed to retrieve members for team '$TeamId'. $($_.Exception.Message)"
    }

    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

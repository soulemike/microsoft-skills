#Requires -Version 7.2
<#
.SYNOPSIS
    Gets Microsoft Teams channels for a team.

.DESCRIPTION
    Retrieves Microsoft Teams channel information through Microsoft Graph v1.0.
    When ChannelId is provided, the script returns the specified channel from
    /teams/{team-id}/channels/{channel-id}. Otherwise, it lists all channels in
    the team from /teams/{team-id}/channels and follows Microsoft Graph
    pagination when present.

    For channel-adjacent Teams operations such as message sub-resources, use
    Invoke-TeamsGraphRequest.ps1 directly with the required Graph path.

.PARAMETER TeamId
    The Microsoft Teams team identifier.

.PARAMETER ChannelId
    Optional channel identifier. When supplied, only the specified channel is
    returned.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.OUTPUTS
    System.Object

.EXAMPLE
    ./skills/teams/Get-TeamsChannel.ps1 -TeamId $teamId -AuthContext $context

.EXAMPLE
    ./skills/teams/Get-TeamsChannel.ps1 -TeamId $teamId -ChannelId $channelId -AuthContext $context
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
        "/$TeamId/channels/$ChannelId"
    }
    else {
        "/$TeamId/channels"
    }

    $response = & $invokeTeamsGraphRequestPath -Uri $requestUri -Method 'GET' -AuthContext $AuthContext

    if ($PSBoundParameters.ContainsKey('ChannelId')) {
        return $response
    }

    return ConvertFrom-TeamsCollectionResponse -Response $response
}
catch {
    $message = if ($PSBoundParameters.ContainsKey('ChannelId')) {
        "Failed to retrieve Teams channel '$ChannelId' from team '$TeamId'. $($_.Exception.Message)"
    }
    else {
        "Failed to list Teams channels for team '$TeamId'. $($_.Exception.Message)"
    }

    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

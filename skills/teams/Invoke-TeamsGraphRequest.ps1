#Requires -Version 7.2
<#
.SYNOPSIS
    Invokes a Microsoft Teams Microsoft Graph REST request.

.DESCRIPTION
    Provides a thin Teams-focused wrapper around the shared Invoke-SkillRestMethod
    helper from Common.psm1. Relative URIs are resolved against the Microsoft
    Graph v1.0 Teams endpoint, and relative paths are automatically prefixed with
    /teams when needed.

    When Microsoft Graph returns @odata.nextLink for a GET request, the wrapper
    automatically follows the continuation links and returns the aggregated item
    collection. Non-paginated responses are returned unchanged.

.PARAMETER Uri
    A Teams-relative URI such as /{team-id}/channels, /{team-id}/members, or an
    absolute Microsoft Graph nextLink URL.

.PARAMETER Method
    The HTTP method to use. Defaults to GET.

.PARAMETER Body
    Optional request body.

.PARAMETER ContentType
    Request content type. Defaults to application/json.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.OUTPUTS
    System.Object

.EXAMPLE
    ./skills/teams/Invoke-TeamsGraphRequest.ps1 -AuthContext $context -Uri '/{team-id}/channels'

.EXAMPLE
    ./skills/teams/Invoke-TeamsGraphRequest.ps1 -AuthContext $context -Uri '/{team-id}/channels/{channel-id}/members'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Uri,

    [Parameter()]
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')]
    [string]$Method = 'GET',

    [Parameter()]
    [AllowNull()]
    [object]$Body,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ContentType = 'application/json',

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

function Resolve-TeamsRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [string]$GraphBaseUri
    )

    if ([System.Uri]::IsWellFormedUriString($RequestUri, [System.UriKind]::Absolute)) {
        return $RequestUri
    }

    $relativeUri = if ($RequestUri.StartsWith('/')) {
        $RequestUri
    }
    else {
        "/$RequestUri"
    }

    if ($relativeUri -notmatch '^/teams(?:/|$)') {
        $relativeUri = "/teams$relativeUri"
    }

    return '{0}{1}' -f $GraphBaseUri.TrimEnd('/'), $relativeUri
}

function Get-ResponseItemCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response -and $Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }

    return @()
}

function Get-NextLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response -and $Response.PSObject.Properties.Name -contains '@odata.nextLink') {
        return $Response.'@odata.nextLink'
    }

    return $null
}

try {
    $environment = if ($AuthContext.ContainsKey('Environment') -and $AuthContext.Environment) {
        [string]$AuthContext.Environment
    }
    else {
        'AzureCloud'
    }

    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    $graphEndpoint = $endpoints.Graph.TrimEnd('/')
    $graphBaseUri = if ($AuthContext.ContainsKey('BaseUri') -and $AuthContext.BaseUri) {
        [string]$AuthContext.BaseUri
    }
    else {
        '{0}/v1.0' -f $graphEndpoint
    }

    $resolvedAuthContext = Resolve-AuthContext -AuthContext $AuthContext -Resource $graphEndpoint
    $requestUri = Resolve-TeamsRequestUri -RequestUri $Uri -GraphBaseUri $graphBaseUri

    $response = Invoke-SkillRestMethod -Uri $requestUri -Method $Method -Body $Body -ContentType $ContentType -AuthContext $resolvedAuthContext

    if ($Method -ne 'GET') {
        return $response
    }

    $nextLink = Get-NextLink -Response $response
    if (-not $nextLink) {
        return $response
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (Get-ResponseItemCollection -Response $response)) {
        [void]$results.Add($item)
    }

    while ($nextLink) {
        $page = Invoke-SkillRestMethod -Uri $nextLink -Method 'GET' -ContentType $ContentType -AuthContext $resolvedAuthContext
        foreach ($item in (Get-ResponseItemCollection -Response $page)) {
            [void]$results.Add($item)
        }

        $nextLink = Get-NextLink -Response $page
    }

    return $results
}
catch {
    $message = "Teams Graph request failed for URI '$Uri'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

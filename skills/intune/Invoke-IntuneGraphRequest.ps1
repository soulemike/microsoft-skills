#Requires -Version 7.2
<#
.SYNOPSIS
    Invokes a Microsoft Intune Microsoft Graph REST request.

.DESCRIPTION
    Provides an Intune-focused Graph wrapper around Invoke-SkillRestMethod from
    Common.psm1. Relative URIs are resolved against the selected Graph API
    version and automatically prefixed with /deviceManagement when needed.

    Use Graph v1.0 for classic Intune device and policy operations whenever
    possible. Use -ApiVersion beta only for beta-required capabilities such as
    settings catalog configuration policies under
    /deviceManagement/configurationPolicies.

    When Microsoft Graph returns @odata.nextLink for a GET request, the wrapper
    automatically follows the continuation links and returns the aggregated item
    collection. Non-paginated responses are returned unchanged.

.PARAMETER Uri
    An Intune-relative URI such as /managedDevices or /configurationPolicies, or
    an absolute Microsoft Graph nextLink URL.

.PARAMETER Method
    The HTTP method to use. Defaults to GET.

.PARAMETER Body
    Optional request body.

.PARAMETER ContentType
    Request content type. Defaults to application/json.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.ps1 or another
    compatible helper.

.PARAMETER ApiVersion
    Graph API version to target. Defaults to v1.0.

.OUTPUTS
    System.Object

.EXAMPLE
    ./skills/intune/Invoke-IntuneGraphRequest.ps1 -AuthContext $context -Uri '/managedDevices'

.EXAMPLE
    ./skills/intune/Invoke-IntuneGraphRequest.ps1 -AuthContext $context -Uri '/configurationPolicies' -ApiVersion beta
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
    [hashtable]$AuthContext,

    [Parameter()]
    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion = 'v1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

function Resolve-IntuneRequestUri {
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

    if ($relativeUri -notmatch '^/deviceManagement(?:/|$)') {
        $relativeUri = "/deviceManagement$relativeUri"
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
    $graphBaseUri = '{0}/{1}' -f $graphEndpoint, $ApiVersion

    $resolvedAuthContext = Resolve-AuthContext -AuthContext $AuthContext -Resource $graphEndpoint
    $requestUri = Resolve-IntuneRequestUri -RequestUri $Uri -GraphBaseUri $graphBaseUri

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
    $message = "Intune Graph request failed for URI '$Uri' using API version '$ApiVersion'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

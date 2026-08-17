#Requires -Version 7.2
<#
.SYNOPSIS
Invokes a Dataverse Web API request.

.DESCRIPTION
Wraps the shared Invoke-SkillRestMethod helper with Dataverse-specific OData
headers, relative URI handling, and optional pagination over @odata.nextLink.

.PARAMETER Uri
The request URI relative to the Dataverse Web API base URI. Absolute nextLink
URIs are also supported.

.PARAMETER AuthContext
The Dataverse connection context returned by Connect-DataverseApi.ps1.

.PARAMETER Paginate
When specified for GET requests, follows @odata.nextLink until all pages are
retrieved and returns the combined value array.

.OUTPUTS
Object

.EXAMPLE
./Invoke-DataverseRequest.ps1 -AuthContext $ctx -Uri '/accounts?$select=name' -Paginate

.EXAMPLE
./Invoke-DataverseRequest.ps1 -AuthContext $ctx -Method POST -Uri '/accounts' -Body @{ name = 'Contoso' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Uri,

    [Parameter()]
    [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
    [string]$Method = 'GET',

    [Parameter()]
    [object]$Body,

    [Parameter()]
    [string]$ContentType = 'application/json; charset=utf-8',

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext,

    [Parameter()]
    [switch]$Paginate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force

function Get-ResolvedDataverseUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestUri,
        [Parameter(Mandatory)][hashtable]$Context
    )

    if ([Uri]::IsWellFormedUriString($RequestUri, [UriKind]::Absolute)) {
        return $RequestUri
    }

    if (-not $Context.BaseUri) {
        if (-not $Context.EnvironmentUrl) {
            throw 'AuthContext must include BaseUri or EnvironmentUrl.'
        }

        $environmentRoot = $Context.EnvironmentUrl.TrimEnd('/')
        $Context.BaseUri = "$environmentRoot/api/data/v9.2"
    }

    $baseUri = $Context.BaseUri.TrimEnd('/')
    $relativeUri = $RequestUri.TrimStart('/')
    return "$baseUri/$relativeUri"
}

function New-DataverseHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HttpMethod,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $headers = [ordered]@{
        Accept = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version' = '4.0'
    }

    if ($HttpMethod -ne 'GET' -and $Context.ContainsKey('RequestDigest') -and $Context.RequestDigest) {
        $headers['X-RequestDigest'] = [string]$Context.RequestDigest
    }

    return $headers
}

try {
    if ($Paginate -and $Method -ne 'GET') {
        throw 'The Paginate switch is only supported for GET requests.'
    }

    $headers = New-DataverseHeaders -HttpMethod $Method -Context $AuthContext
    $resolvedUri = Get-ResolvedDataverseUri -RequestUri $Uri -Context $AuthContext

    if (-not $Paginate) {
        return Invoke-SkillRestMethod -Uri $resolvedUri -AuthContext $AuthContext -Method $Method -Body $Body -ContentType $ContentType -AdditionalHeaders $headers
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $resolvedUri

    while ($nextUri) {
        $response = Invoke-SkillRestMethod -Uri $nextUri -AuthContext $AuthContext -Method 'GET' -ContentType $ContentType -AdditionalHeaders $headers
        if ($null -ne $response.value) {
            foreach ($item in $response.value) {
                [void]$results.Add($item)
            }
        }

        $nextUri = if ($response -and $response.PSObject.Properties['@odata.nextLink']) { [string]$response.PSObject.Properties['@odata.nextLink'].Value } else { $null }
    }

    return $results
}
catch {
    $message = "Dataverse request failed for '$Uri' using method '$Method'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

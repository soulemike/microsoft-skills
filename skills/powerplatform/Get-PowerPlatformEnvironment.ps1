#Requires -Version 7.2
<#
.SYNOPSIS
    Lists Power Platform environments from the Business Application Platform (BAP) API.

.DESCRIPTION
    Uses a connection context returned from Connect-PowerPlatformApi.ps1 and
    calls the Power Platform BAP admin environments endpoint. The script uses
    the shared REST helper from Common.psm1 and follows any nextLink values
    returned by the API until all pages have been collected.

.PARAMETER Context
    Connection context hashtable returned from Connect-PowerPlatformApi.ps1.
    The context must contain at least Token and BaseUri, and should also include
    the resolved Environment.

.PARAMETER ApiVersion
    BAP API version to use for the environments list request. Defaults to the
    documented admin environments version.

.PARAMETER Expand
    Optional comma-separated property expansions to request from the BAP API.

.OUTPUTS
    PSCustomObject[]

.EXAMPLE
    $context = ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
    ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $context

.EXAMPLE
    ./skills/powerplatform/Get-PowerPlatformEnvironment.ps1 -Context $context -Expand 'properties.capacity,properties.addons'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '2020-10-01',

    [Parameter()]
    [string]$Expand
)

. $PSScriptRoot/../Common.psm1
if (-not (Get-Command -Name 'Get-EnvironmentEndpoints' -ErrorAction SilentlyContinue) -or -not (Get-Command -Name 'Invoke-SkillRestMethod' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return @{} + $InputObject
    }

    $converted = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $converted[$property.Name] = $property.Value
    }

    return $converted
}

function Test-AllowedPowerPlatformUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$ExpectedBaseUri
    )

    $candidateUri = [Uri]$Uri
    $expectedUri = [Uri]$ExpectedBaseUri

    return $candidateUri.Scheme -eq 'https' -and $candidateUri.Host -eq $expectedUri.Host
}

function Resolve-PowerPlatformBaseUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConnectionContext
    )

    if ($ConnectionContext.BaseUri) {
        $resolvedBaseUri = ([string]$ConnectionContext.BaseUri).TrimEnd('/')

        if (-not [Uri]::IsWellFormedUriString($resolvedBaseUri, [UriKind]::Absolute)) {
            throw "The supplied BaseUri '$resolvedBaseUri' is not a valid absolute URI."
        }

        if ($ConnectionContext.Environment) {
            $expectedBaseUri = ([string](Get-EnvironmentEndpoints -Environment ([string]$ConnectionContext.Environment)).Bap).TrimEnd('/')
            if (-not (Test-AllowedPowerPlatformUri -Uri $resolvedBaseUri -ExpectedBaseUri $expectedBaseUri)) {
                throw "The supplied BaseUri '$resolvedBaseUri' does not match the expected BAP endpoint for environment '$($ConnectionContext.Environment)'."
            }
        }
        elseif (-not (Test-AllowedPowerPlatformUri -Uri $resolvedBaseUri -ExpectedBaseUri $resolvedBaseUri)) {
            throw "The supplied BaseUri '$resolvedBaseUri' must use HTTPS."
        }

        return $resolvedBaseUri
    }

    if ($ConnectionContext.Environment) {
        $endpoints = Get-EnvironmentEndpoints -Environment ([string]$ConnectionContext.Environment)
        return ([string]$endpoints.Bap).TrimEnd('/')
    }

    throw 'The supplied context does not include BaseUri or Environment.'
}

function Resolve-NextLink {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Response,

        [Parameter(Mandatory)]
        [string]$BaseUri
    )

    if (-not $Response) {
        return $null
    }

    $candidate = $null
    foreach ($propertyName in @('nextLink', '@odata.nextLink')) {
        $property = $Response.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $candidate = [string]$property.Value
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    if ([Uri]::IsWellFormedUriString($candidate, [UriKind]::Absolute)) {
        if (-not (Test-AllowedPowerPlatformUri -Uri $candidate -ExpectedBaseUri $BaseUri)) {
            throw "The response contained a nextLink outside the expected BAP endpoint: '$candidate'."
        }

        return $candidate
    }

    $baseUriObject = [Uri]$BaseUri
    return [Uri]::new($baseUriObject, $candidate).AbsoluteUri
}

function New-EnvironmentRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUri,

        [Parameter(Mandatory)]
        [string]$RequestedApiVersion,

        [Parameter()]
        [string]$RequestedExpand
    )

    $queryParameters = [System.Collections.Generic.List[string]]::new()
    $queryParameters.Add('api-version={0}' -f [System.Uri]::EscapeDataString($RequestedApiVersion))

    if (-not [string]::IsNullOrWhiteSpace($RequestedExpand)) {
        $queryParameters.Add('%24expand={0}' -f [System.Uri]::EscapeDataString($RequestedExpand))
    }

    return '{0}/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?{1}' -f $BaseUri.TrimEnd('/'), ($queryParameters -join '&')
}

try {
    $normalizedContext = ConvertTo-Hashtable -InputObject $Context

    if (-not $normalizedContext -or -not $normalizedContext.Token) {
        throw 'The supplied context does not contain a bearer token.'
    }

    $baseUri = Resolve-PowerPlatformBaseUri -ConnectionContext $normalizedContext
    $requestUri = New-EnvironmentRequestUri -BaseUri $baseUri -RequestedApiVersion $ApiVersion -RequestedExpand $Expand
    $authContext = @{} + $normalizedContext
    $headers = [ordered]@{
        Accept = 'application/json'
    }

    $environments = [System.Collections.Generic.List[object]]::new()
    $nextUri = $requestUri

    while ($nextUri) {
        $response = Invoke-SkillRestMethod -Uri $nextUri -AuthContext $authContext -Method 'GET' -AdditionalHeaders $headers

        if ($response -and $response.value) {
            foreach ($environmentRecord in $response.value) {
                [void]$environments.Add([pscustomobject]$environmentRecord)
            }
        }

        $nextUri = Resolve-NextLink -Response $response -BaseUri $baseUri
    }

    return $environments
}
catch {
    $message = 'Failed to list Power Platform environments. {0}' -f $_.Exception.Message
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

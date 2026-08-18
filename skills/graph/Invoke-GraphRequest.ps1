#Requires -Version 7.2
<#
.SYNOPSIS
    Invokes a Microsoft Graph REST request.

.DESCRIPTION
    Wraps Microsoft Graph REST calls using the shared Common.psm1 helpers for
    HTTP execution and pagination. The script supports relative Graph URIs,
    automatic pagination, basic in-memory caching for idempotent GET requests,
    exponential backoff for throttling and transient failures, and improved
    Graph-specific error messages.

.PARAMETER Uri
    Relative Microsoft Graph path such as /users or an absolute nextLink URL.

.PARAMETER Method
    HTTP method to use. Defaults to GET.

.PARAMETER Body
    Optional request payload.

.PARAMETER ContentType
    Content type for the request body. Defaults to application/json.

.PARAMETER AuthContext
    Graph authentication context returned by Connect-GraphApi.

.PARAMETER Paginate
    Automatically follows @odata.nextLink and returns the aggregated value
    collection.

.OUTPUTS
    Object returned by Microsoft Graph, or a collection of aggregated items
    when -Paginate is specified.

.EXAMPLE
    $context = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
    ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Uri '/users' -Paginate

.EXAMPLE
    ./skills/graph/Invoke-GraphRequest.ps1 -AuthContext $context -Method POST -Uri '/groups' -Body @{ displayName = 'Example'; mailEnabled = $false; mailNickname = 'example'; securityEnabled = $true }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Uri,

    [Parameter()]
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')]
    [string]$Method = 'GET',

    [Parameter()]
    [object]$Body,

    [Parameter()]
    [string]$ContentType = 'application/json',

    [Parameter(Mandatory)]
    [hashtable]$AuthContext,

    [Parameter()]
    [switch]$Paginate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..') -ChildPath 'Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

if (-not (Get-Variable -Scope Script -Name GraphRequestCache -ErrorAction SilentlyContinue)) {
    $script:GraphRequestCache = @{}
}

function Resolve-GraphRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ([System.Uri]::IsWellFormedUriString($RequestUri, [System.UriKind]::Absolute)) {
        return $RequestUri
    }

    if (-not $Context.BaseUri) {
        throw 'AuthContext must contain BaseUri when a relative Graph URI is used.'
    }

    $baseUri = $Context.BaseUri.TrimEnd('/')
    $relativePath = $RequestUri.TrimStart('/')

    return '{0}/{1}' -f $baseUri, $relativePath
}

function Get-GraphRetryMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = $null
    $retryAfter = $null
    $reasonPhrase = $null
    $rawContent = $null
    $graphCode = $null
    $graphMessage = $null
    $requestId = $null
    $requestDate = $null

    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }
    if ($response) {
        try {
            if ($response.StatusCode -is [System.Enum]) {
                $statusCode = [int]$response.StatusCode
            }
            elseif ($null -ne $response.StatusCode) {
                $statusCode = [int]$response.StatusCode.value__
            }
        }
        catch {
            $statusCode = 0
        }

        try {
            $reasonPhrase = $response.ReasonPhrase
        }
        catch {
            $reasonPhrase = $null
        }

        try {
            $retryAfter = $response.Headers['Retry-After']
            if ($retryAfter -is [System.Array]) {
                $retryAfter = $retryAfter[0]
            }
        }
        catch {
            $retryAfter = $null
        }

        try {
            if ($response.Content) {
                $rawContent = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        }
        catch {
            $rawContent = $null
        }
    }

    if (-not $rawContent -and $ErrorRecord.PSObject.Properties['ErrorDetails'] -and $ErrorRecord.ErrorDetails.PSObject.Properties['Message']) {
        $rawContent = $ErrorRecord.ErrorDetails.Message
    }

    if ($rawContent) {
        try {
            $errorPayload = $rawContent | ConvertFrom-Json -Depth 10
            if ($errorPayload.PSObject.Properties['error']) {
                $errorObj = $errorPayload.error
                if ($errorObj.PSObject.Properties['code']) {
                    $graphCode = $errorObj.code
                }
                if ($errorObj.PSObject.Properties['message']) {
                    $graphMessage = $errorObj.message
                }
                if ($errorObj.PSObject.Properties['innerError']) {
                    $innerError = $errorObj.innerError
                    if ($innerError.PSObject.Properties['request-id']) {
                        $requestId = $innerError.'request-id'
                    }
                    if ($innerError.PSObject.Properties['date']) {
                        $requestDate = $innerError.date
                    }
                }
            }
        }
        catch {
            $graphCode = $null
        }
    }

    return @{
        StatusCode  = $statusCode
        RetryAfter  = $retryAfter
        ReasonPhrase = $reasonPhrase
        RawContent  = $rawContent
        GraphCode   = $graphCode
        GraphMessage = $graphMessage
        RequestId   = $requestId
        RequestDate = $requestDate
    }
}

function New-GraphRequestException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedUri,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$GraphError,

        [Parameter(Mandatory)]
        [System.Exception]$InnerException
    )

    $messageParts = [System.Collections.Generic.List[string]]::new()
    $messageParts.Add("Microsoft Graph request failed for '$ResolvedUri'.")

    if ($GraphError.StatusCode) {
        $statusLine = "HTTP $($GraphError.StatusCode)"
        if ($GraphError.ReasonPhrase) {
            $statusLine = "$statusLine $($GraphError.ReasonPhrase)"
        }

        $messageParts.Add($statusLine)
    }

    if ($GraphError.GraphCode) {
        $messageParts.Add("Graph error code: $($GraphError.GraphCode)")
    }

    if ($GraphError.GraphMessage) {
        $messageParts.Add($GraphError.GraphMessage)
    }
    elseif ($GraphError.RawContent) {
        $messageParts.Add($GraphError.RawContent)
    }

    if ($GraphError.RequestId) {
        $messageParts.Add("request-id: $($GraphError.RequestId)")
    }

    return [System.InvalidOperationException]::new(($messageParts -join ' '), $InnerException)
}

function Get-GraphCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedUri,

        [Parameter(Mandatory)]
        [string]$RequestMethod,

        [Parameter(Mandatory)]
        [string]$RequestContentType,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [bool]$IsPaginated
    )

    return '{0}|{1}|{2}|{3}|{4}' -f $RequestMethod, $ResolvedUri, $RequestContentType, $Context.TenantId, $IsPaginated
}

function Get-GraphCacheTtl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $defaultExpiry = (Get-Date).AddMinutes(5)
    if (-not $Context.ContainsKey('ExpiresOn') -or -not $Context.ExpiresOn) {
        return $defaultExpiry
    }

    if ($Context.ExpiresOn -lt $defaultExpiry) {
        return $Context.ExpiresOn
    }

    return $defaultExpiry
}

$resolvedUri = Resolve-GraphRequestUri -RequestUri $Uri -Context $AuthContext

if (-not $AuthContext.Token) {
    throw 'AuthContext must contain a Graph access token.'
}

if ($AuthContext.ContainsKey('ExpiresOn') -and $AuthContext.ExpiresOn -and $AuthContext.ExpiresOn -le (Get-Date)) {
    throw 'The supplied Graph access token has expired. Re-run Connect-GraphApi to acquire a fresh token.'
}

$isCacheable = $Method -eq 'GET' -and -not $PSBoundParameters.ContainsKey('Body')
$cacheKey = Get-GraphCacheKey -ResolvedUri $resolvedUri -RequestMethod $Method -RequestContentType $ContentType -Context $AuthContext -IsPaginated $Paginate.IsPresent

if ($isCacheable -and $script:GraphRequestCache.ContainsKey($cacheKey)) {
    $cacheEntry = $script:GraphRequestCache[$cacheKey]
    if ($cacheEntry.ExpiresOn -gt (Get-Date)) {
        return $cacheEntry.Response
    }

    $null = $script:GraphRequestCache.Remove($cacheKey)
}

$maxAttempts = 4
$attempt = 0

while ($attempt -lt $maxAttempts) {
    $attempt++

    try {
        $result = if ($Paginate) {
            Get-PaginatedResults -Uri $resolvedUri -AuthContext $AuthContext
        }
        else {
            Invoke-SkillRestMethod `
                -Uri $resolvedUri `
                -AuthContext $AuthContext `
                -Method $Method `
                -Body $Body `
                -ContentType $ContentType `
                -RetryCount 4 `
                -RetryDelaySec 2
        }

        if ($isCacheable) {
            $script:GraphRequestCache[$cacheKey] = @{
                Response  = $result
                ExpiresOn = Get-GraphCacheTtl -Context $AuthContext
            }
        }

        return $result
    }
    catch {
        $graphError = Get-GraphRetryMetadata -ErrorRecord $_
        $shouldRetry = $graphError.StatusCode -eq 429 -or ($graphError.StatusCode -ge 500 -and $graphError.StatusCode -lt 600)

        if ($shouldRetry -and $attempt -lt $maxAttempts) {
            $delaySeconds = if ($graphError.RetryAfter) {
                [int]$graphError.RetryAfter
            }
            else {
                [int][math]::Pow(2, $attempt)
            }

            Write-Warning ("Graph request to '{0}' returned HTTP {1}. Retrying in {2} second(s) (attempt {3}/{4})." -f $resolvedUri, $graphError.StatusCode, $delaySeconds, $attempt + 1, $maxAttempts)
            Start-Sleep -Seconds $delaySeconds
            continue
        }

        throw (New-GraphRequestException -ResolvedUri $resolvedUri -GraphError $graphError -InnerException $_.Exception)
    }
}

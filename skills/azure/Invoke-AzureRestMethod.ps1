#Requires -Version 7.2
<#
.SYNOPSIS
    Invokes Azure Resource Manager REST API requests.

.DESCRIPTION
    Builds ARM request URIs from a relative path and the supplied authentication
    context, applies api-version when provided, and executes the request through
    the shared retry/throttling helpers in Common.psm1.

    The script supports:
    - Relative ARM URIs such as /subscriptions/{id}/resourceGroups/{name}
    - Full ARM URLs when a nextLink or operation URL is already available
    - ARM pagination through Get-PaginatedResults
    - ARM async metadata capture through Operation-Location,
      Azure-AsyncOperation, Location, and Retry-After response headers

.PARAMETER Uri
    Relative ARM URI or full ARM URL.

.PARAMETER Method
    HTTP method to use.

.PARAMETER Body
    Optional request body. Hashtables are serialized to JSON by the shared
    wrapper.

.PARAMETER ContentType
    Request content type.

.PARAMETER ApiVersion
    ARM api-version query parameter to append when not already present.

.PARAMETER AuthContext
    Azure ARM authentication context returned by Connect-AzureApi.ps1.

.PARAMETER Paginate
    When specified with GET requests, enumerates all pages using the shared
    pagination helper.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    $context = ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
    ./skills/azure/Invoke-AzureRestMethod.ps1 -Uri "/subscriptions/$($context.SubscriptionId)/resourcegroups" -ApiVersion '2021-04-01' -AuthContext $context -Paginate

.EXAMPLE
    ./skills/azure/Invoke-AzureRestMethod.ps1 -Uri "/subscriptions/$sub/resourcegroups/$rg/providers/Microsoft.Storage/storageAccounts/$name" -Method PUT -ApiVersion '2023-05-01' -Body $payload -AuthContext $context
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

    [Parameter(Mandatory)]
    [object]$AuthContext,

    [Parameter()]
    [switch]$Paginate
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot '..' 'Common.psm1'
Import-Module $commonModulePath -Force

function ConvertTo-AuthHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($InputObject -is [hashtable]) {
        return $InputObject
    }

    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }

    return $table
}

function Test-IsAbsoluteUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputString
    )

    $absoluteUri = $null
    if (-not [System.Uri]::TryCreate($InputString, [System.UriKind]::Absolute, [ref]$absoluteUri)) {
        return $false
    }

    return $absoluteUri.IsAbsoluteUri -and $absoluteUri.Scheme -in @('http', 'https')
}

function Resolve-AzureRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputUri,

        [Parameter()]
        [string]$BaseUri
    )

    if (Test-IsAbsoluteUri -InputString $InputUri) {
        return $InputUri
    }

    if ([string]::IsNullOrWhiteSpace($BaseUri)) {
        throw 'AuthContext.BaseUri or AuthContext.ArmEndpoint is required when -Uri is not an absolute URL.'
    }

    $baseAddress = [System.Uri]::new(('{0}/' -f $BaseUri.TrimEnd('/')))
    $relativePath = $InputUri.TrimStart('/')

    return [System.Uri]::new($baseAddress, $relativePath).AbsoluteUri
}

function Add-ApiVersionToUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputUri,

        [Parameter()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version) -or $InputUri -match '([?&])api-version=') {
        return $InputUri
    }

    if ($InputUri.Contains('?')) {
        return ('{0}&api-version={1}' -f $InputUri, $Version)
    }

    return ('{0}?api-version={1}' -f $InputUri, $Version)
}

function Get-HeaderValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    $value = $null
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ($key -ieq $Name) {
                $value = $Headers[$key]
                break
            }
        }
    }
    else {
        foreach ($property in $Headers.PSObject.Properties) {
            if ($property.Name -ieq $Name) {
                $value = $property.Value
                break
            }
        }
    }

    if ($null -eq $value) {
        return $null
    }

    if ($value -is [string]) {
        return $value
    }

    if ($value -is [System.Collections.IEnumerable]) {
        $items = foreach ($item in $value) {
            if ($null -ne $item) {
                [string]$item
            }
        }

        if ($items) {
            return ($items -join ', ')
        }
    }

    return [string]$value
}

function ConvertTo-ResponseHeaderHashtable {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Headers
    )

    if ($null -eq $Headers) {
        return $null
    }

    $result = [ordered]@{}
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            $result[[string]$key] = Get-HeaderValue -Headers $Headers -Name ([string]$key)
        }
    }
    else {
        foreach ($property in $Headers.PSObject.Properties) {
            $result[$property.Name] = Get-HeaderValue -Headers $Headers -Name $property.Name
        }
    }

    return [pscustomobject]$result
}

function ConvertFrom-ResponseContent {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Content,

        [Parameter()]
        [AllowNull()]
        [object]$Headers
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    $contentType = Get-HeaderValue -Headers $Headers -Name 'Content-Type'
    if ($contentType -and $contentType -match 'json') {
        try {
            return $Content | ConvertFrom-Json -Depth 20
        }
        catch {
            return $Content
        }
    }

    return $Content
}

function Invoke-WebRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [string]$HttpMethod,

        [Parameter()]
        [AllowNull()]
        [object]$RequestBody,

        [Parameter(Mandatory)]
        [string]$RequestContentType,

        [Parameter()]
        [int]$RetryCount = 3,

        [Parameter()]
        [int]$RetryDelaySec = 2
    )

    $headers = @{
        Authorization = "Bearer $($ResolvedAuthContext.Token)"
        'Content-Type' = $RequestContentType
    }

    $bodyContent = $null
    if ($PSBoundParameters.ContainsKey('RequestBody') -and $null -ne $RequestBody) {
        if ($RequestBody -is [hashtable] -or $RequestBody -is [System.Collections.Specialized.OrderedDictionary]) {
            $bodyContent = $RequestBody | ConvertTo-Json -Depth 10
        }
        else {
            $bodyContent = $RequestBody
        }
    }

    $attempt = 0
    while ($attempt -le $RetryCount) {
        try {
            $invokeParams = @{
                Uri = $RequestUri
                Method = $HttpMethod
                Headers = $headers
                SkipHttpErrorCheck = $true
            }

            if ($null -ne $bodyContent) {
                $invokeParams.Body = $bodyContent
            }

            $response = Invoke-WebRequest @invokeParams
            $statusCode = [int]$response.StatusCode

            if ($statusCode -eq 401) {
                throw 'Authentication token expired or invalid (HTTP 401). Please re-authenticate.'
            }

            if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                if ($attempt -ge $RetryCount) {
                    throw "Azure REST request failed with HTTP $statusCode after $($attempt + 1) attempts."
                }

                $retryAfter = Get-HeaderValue -Headers $response.Headers -Name 'Retry-After'
                $delay = if ($retryAfter) { [int]$retryAfter } else { $RetryDelaySec * [math]::Pow(2, $attempt) }
                Write-Warning "Request throttled/transient failure (HTTP $statusCode). Retrying in ${delay}s... (attempt $($attempt + 1)/$RetryCount)"
                Start-Sleep -Seconds $delay
                $attempt++
                continue
            }

            if ($statusCode -ge 400) {
                $errorContent = if ([string]::IsNullOrWhiteSpace($response.Content)) { 'No response body returned.' } else { $response.Content }
                throw "Azure REST request failed with HTTP $statusCode. $errorContent"
            }

            return [pscustomobject][ordered]@{
                StatusCode = $statusCode
                Headers = ConvertTo-ResponseHeaderHashtable -Headers $response.Headers
                Value = ConvertFrom-ResponseContent -Content $response.Content -Headers $response.Headers
            }
        }
        catch {
            if ($_.Exception.Message -match 'Authentication token expired or invalid' -or $attempt -ge $RetryCount) {
                throw
            }

            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                    $attempt++
                    $delay = $RetryDelaySec * [math]::Pow(2, $attempt - 1)
                    Write-Warning "Request throttled/transient failure (HTTP $statusCode). Retrying in ${delay}s... (attempt $attempt/$RetryCount)"
                    Start-Sleep -Seconds $delay
                    continue
                }
            }

            throw
        }
    }
}

function Invoke-WithHeaderCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [string]$HttpMethod,

        [Parameter()]
        [AllowNull()]
        [object]$RequestBody,

        [Parameter(Mandatory)]
        [string]$RequestContentType
    )

    $responseHeadersVariableName = 'global:OpenCode_InvokeAzureRestMethod_ResponseHeaders'
    $statusCodeVariableName = 'global:OpenCode_InvokeAzureRestMethod_StatusCode'
    $previousResponseHeaders = Get-Variable -Name 'OpenCode_InvokeAzureRestMethod_ResponseHeaders' -Scope Global -ErrorAction SilentlyContinue
    $previousStatusCode = Get-Variable -Name 'OpenCode_InvokeAzureRestMethod_StatusCode' -Scope Global -ErrorAction SilentlyContinue

    Set-Variable -Name 'OpenCode_InvokeAzureRestMethod_ResponseHeaders' -Scope Global -Value $null
    Set-Variable -Name 'OpenCode_InvokeAzureRestMethod_StatusCode' -Scope Global -Value $null

    $savedDefaults = @{}
    $defaultKeys = @(
        'Invoke-RestMethod:ResponseHeadersVariable'
        'Invoke-RestMethod:StatusCodeVariable'
    )

    foreach ($key in $defaultKeys) {
        if ($PSDefaultParameterValues.ContainsKey($key)) {
            $savedDefaults[$key] = $PSDefaultParameterValues[$key]
        }
    }

    try {
        $PSDefaultParameterValues['Invoke-RestMethod:ResponseHeadersVariable'] = $responseHeadersVariableName
        $PSDefaultParameterValues['Invoke-RestMethod:StatusCodeVariable'] = $statusCodeVariableName

        $invokeParams = @{
            Uri = $RequestUri
            AuthContext = $ResolvedAuthContext
            Method = $HttpMethod
            ContentType = $RequestContentType
        }

        if ($PSBoundParameters.ContainsKey('RequestBody')) {
            $invokeParams.Body = $RequestBody
        }

        $value = Invoke-SkillRestMethod @invokeParams

        $capturedHeaders = (Get-Variable -Name 'OpenCode_InvokeAzureRestMethod_ResponseHeaders' -Scope Global -ErrorAction SilentlyContinue).Value
        $capturedStatusCode = (Get-Variable -Name 'OpenCode_InvokeAzureRestMethod_StatusCode' -Scope Global -ErrorAction SilentlyContinue).Value

        return [pscustomobject][ordered]@{
            StatusCode = $capturedStatusCode
            Headers = ConvertTo-ResponseHeaderHashtable -Headers $capturedHeaders
            Value = $value
        }
    }
    finally {
        foreach ($key in $defaultKeys) {
            if ($savedDefaults.ContainsKey($key)) {
                $PSDefaultParameterValues[$key] = $savedDefaults[$key]
            }
            else {
                $null = $PSDefaultParameterValues.Remove($key)
            }
        }

        if ($null -ne $previousResponseHeaders) {
            Set-Variable -Name 'OpenCode_InvokeAzureRestMethod_ResponseHeaders' -Scope Global -Value $previousResponseHeaders.Value
        }
        else {
            Remove-Variable -Name 'OpenCode_InvokeAzureRestMethod_ResponseHeaders' -Scope Global -ErrorAction SilentlyContinue
        }

        if ($null -ne $previousStatusCode) {
            Set-Variable -Name 'OpenCode_InvokeAzureRestMethod_StatusCode' -Scope Global -Value $previousStatusCode.Value
        }
        else {
            Remove-Variable -Name 'OpenCode_InvokeAzureRestMethod_StatusCode' -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($Paginate -and $Method -ne 'GET') {
        throw 'The -Paginate switch is only supported for GET requests.'
    }

    $resolvedAuthContext = ConvertTo-AuthHashtable -InputObject $AuthContext
    if (-not $resolvedAuthContext.Token) {
        throw 'AuthContext.Token is required.'
    }

    $baseUri = if ($resolvedAuthContext.BaseUri) {
        [string]$resolvedAuthContext.BaseUri
    }
    else {
        [string]$resolvedAuthContext.ArmEndpoint
    }

    $requestUri = Resolve-AzureRequestUri -InputUri $Uri -BaseUri $baseUri
    $requestUri = Add-ApiVersionToUri -InputUri $requestUri -Version $ApiVersion

    if ($Paginate) {
        $items = Get-PaginatedResults -Uri $requestUri -AuthContext $resolvedAuthContext
        return [pscustomobject][ordered]@{
            RequestUri = $requestUri
            StatusCode = 200
            Value = @($items)
            Headers = $null
            OperationLocation = $null
            AzureAsyncOperation = $null
            Location = $null
            RetryAfter = $null
            Paginated = $true
        }
    }

    $result = if ($Method -in @('POST', 'PUT', 'PATCH', 'DELETE')) {
        Invoke-WebRequestWithRetry -RequestUri $requestUri -ResolvedAuthContext $resolvedAuthContext -HttpMethod $Method -RequestBody $Body -RequestContentType $ContentType
    }
    else {
        $capturedResult = Invoke-WithHeaderCapture -RequestUri $requestUri -ResolvedAuthContext $resolvedAuthContext -HttpMethod $Method -RequestBody $Body -RequestContentType $ContentType
        if (-not $capturedResult.StatusCode) {
            $capturedResult.StatusCode = 200
        }

        $capturedResult
    }

    return [pscustomobject][ordered]@{
        RequestUri = $requestUri
        StatusCode = $result.StatusCode
        Value = $result.Value
        Headers = $result.Headers
        OperationLocation = Get-HeaderValue -Headers $result.Headers -Name 'Operation-Location'
        AzureAsyncOperation = Get-HeaderValue -Headers $result.Headers -Name 'Azure-AsyncOperation'
        Location = Get-HeaderValue -Headers $result.Headers -Name 'Location'
        RetryAfter = Get-HeaderValue -Headers $result.Headers -Name 'Retry-After'
        Paginated = $false
    }
}
catch {
    $message = "Azure REST request failed for URI '$Uri'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

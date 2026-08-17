#Requires -Version 7.2
<#
.SYNOPSIS
    Sends data to Log Analytics with DCR-first ingestion and Data Collector fallback.

.DESCRIPTION
    Attempts log ingestion through the DCR-based Logs Ingestion API first. If
    the DCR request fails with HTTP 401 or 403, the script falls back to the
    legacy HTTP Data Collector API when a workspace shared key is available.

    The Data Collector API request is signed with the workspace shared key and
    sent as newline-delimited JSON using api-version=2016-04-01-jsonlines.

.PARAMETER WorkspaceId
    Customer ID of the Log Analytics workspace.

.PARAMETER WorkspaceSharedKey
    Primary or secondary shared key for the workspace. Required only when the
    DCR path fails and fallback is needed.

.PARAMETER DceUri
    Logs ingestion endpoint URI returned by the DCE.

.PARAMETER DcrImmutableId
    Immutable ID of the DCR.

.PARAMETER StreamName
    DCR stream name to target.

.PARAMETER Data
    Array of objects representing log records.

.PARAMETER AuthContext
    Authentication context used for the DCR ingestion attempt.

.PARAMETER DataCollectorLogType
    Optional explicit Log-Type value for the HTTP Data Collector API fallback.
    When omitted, the script derives a fallback Log-Type from StreamName.

.OUTPUTS
    Hashtable describing success or failure and which ingestion path was used.

.EXAMPLE
    ./skills/loganalytics/Send-LogAnalyticsData.ps1 -WorkspaceId $workspaceId -WorkspaceSharedKey $sharedKey -DceUri $pipeline.DceUri -DcrImmutableId $pipeline.DcrImmutableId -StreamName 'Custom-LogAnalyticsRaw' -Data $records -AuthContext $authContext
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceId,

    [Parameter()]
    [AllowNull()]
    [string]$WorkspaceSharedKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DceUri,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DcrImmutableId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$StreamName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [object[]]$Data,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext,

    [Parameter()]
    [string]$DataCollectorLogType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

function Get-HttpStatusCodeFromException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    if ($response.PSObject.Properties['StatusCode']) {
        $statusCode = $response.PSObject.Properties['StatusCode'].Value
        if ($statusCode -is [int]) {
            return $statusCode
        }

        if ($statusCode.PSObject.Properties['value__']) {
            return [int]$statusCode.PSObject.Properties['value__'].Value
        }
    }

    if ($ErrorRecord.Exception.Message -match 'HTTP\s+(\d{3})') {
        return [int]$Matches[1]
    }

    return $null
}

function Get-AuthEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ($Context.ContainsKey('Environment') -and -not [string]::IsNullOrWhiteSpace([string]$Context.Environment)) {
        return [string]$Context.Environment
    }

    return 'AzureCloud'
}

function ConvertFrom-Base64UrlSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputString
    )

    $normalized = $InputString.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
        0 { }
        default { throw 'Invalid base64url input.' }
    }

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
}

function Get-JwtClaims {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) {
        return $null
    }

    try {
        return ConvertFrom-Base64UrlSegment -InputString $parts[1] | ConvertFrom-Json -Depth 10
    }
    catch {
        return $null
    }
}

function Get-MonitorIngestionTokenAudience {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Environment
    )

    switch ($Environment) {
        'AzureCloud' { return 'https://monitor.azure.com/' }
        'AzureUSGovernment' { return 'https://monitor.azure.us/' }
        'AzureChinaCloud' { return 'https://monitor.azure.cn/' }
        default { throw "Unsupported Azure environment '$Environment'." }
    }
}

function Get-DceHostSuffix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Environment
    )

    switch ($Environment) {
        'AzureCloud' { return '.ingest.monitor.azure.com' }
        'AzureUSGovernment' { return '.ingest.monitor.azure.us' }
        'AzureChinaCloud' { return '.ingest.monitor.azure.cn' }
        default { throw "Unsupported Azure environment '$Environment'." }
    }
}

function Get-DataCollectorHostSuffix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Environment
    )

    switch ($Environment) {
        'AzureCloud' { return 'ods.opinsights.azure.com' }
        'AzureUSGovernment' { return 'ods.opinsights.azure.us' }
        'AzureChinaCloud' { return 'ods.opinsights.azure.cn' }
        default { throw "Unsupported Azure environment '$Environment'." }
    }
}

function Test-TokenAudienceMatch {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$ExpectedAudience
    )

    $claims = Get-JwtClaims -Token $Token
    if ($null -eq $claims -or -not $claims.PSObject.Properties['aud']) {
        return $false
    }

    $actualAudience = [string]$claims.PSObject.Properties['aud'].Value
    return $actualAudience.TrimEnd('/') -eq $ExpectedAudience.TrimEnd('/')
}

function Resolve-DcrAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $environment = Get-AuthEnvironment -Context $Context
    $requiredAudience = Get-MonitorIngestionTokenAudience -Environment $environment

    if ($Context.ContainsKey('Token') -and (Test-TokenAudienceMatch -Token ([string]$Context.Token) -ExpectedAudience $requiredAudience)) {
        return $Context
    }

    $resolvedAuthenticationType = if ($Context.ContainsKey('AuthenticationType') -and $Context.AuthenticationType) {
        [string]$Context.AuthenticationType
    }
    elseif ($Context.ContainsKey('Method') -and $Context.Method) {
        [string]$Context.Method
    }
    else {
        $null
    }

    if ($resolvedAuthenticationType -eq 'ManagedIdentity') {
        $token = Get-ManagedIdentityToken -Resource $requiredAudience
        $resolvedContext = @{} + $Context
        $resolvedContext.Token = $token
        $resolvedContext.Environment = $environment
        return $resolvedContext
    }

    if ($Context.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace([string]$Context.Token)) {
        Write-Warning ('AuthContext.Token is not scoped for the Azure Monitor Logs Ingestion API audience ({0}). Provide a monitor-scoped token in AuthContext or use managed identity so the script can acquire one automatically.' -f $requiredAudience.TrimEnd('/'))
    }

    return $Context
}

function Resolve-DcrRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawDceUri,

        [Parameter(Mandatory)]
        [string]$Environment,

        [Parameter(Mandatory)]
        [string]$ImmutableId,

        [Parameter(Mandatory)]
        [string]$TargetStreamName
    )

    $dceUriObject = $null
    if (-not [System.Uri]::TryCreate($RawDceUri, [System.UriKind]::Absolute, [ref]$dceUriObject)) {
        throw 'DceUri must be an absolute URI.'
    }

    if ($dceUriObject.Scheme -ne 'https') {
        throw 'DceUri must use HTTPS.'
    }

    $expectedHostSuffix = Get-DceHostSuffix -Environment $Environment
    if (-not $dceUriObject.Host.EndsWith($expectedHostSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "DceUri host '$($dceUriObject.Host)' is not valid for Azure Monitor ingestion in environment '$Environment'."
    }

    $normalizedDceUri = $dceUriObject.AbsoluteUri.TrimEnd('/')
    return '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f `
        $normalizedDceUri,
        [System.Uri]::EscapeDataString($ImmutableId),
        [System.Uri]::EscapeDataString($TargetStreamName)
}

function Get-ResponseContentFromException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    if ($response.PSObject.Properties['Content']) {
        return [string]$response.PSObject.Properties['Content'].Value
    }

    return $null
}

function ConvertTo-JsonLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Records
    )

    $jsonLines = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $Records) {
        $jsonLines.Add(($record | ConvertTo-Json -Depth 20 -Compress))
    }

    return ($jsonLines -join "`n")
}

function Get-DataCollectorLogType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputName
    )

    $logType = $InputName
    if ($logType.EndsWith('_CL')) {
        $logType = $logType.Substring(0, $logType.Length - 3)
    }

    $sanitized = ($logType -replace '[^A-Za-z0-9_-]', '')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return 'CustomLog'
    }

    if ($sanitized.Length -gt 100) {
        return $sanitized.Substring(0, 100)
    }

    return $sanitized
}

function New-DataCollectorAuthorizationHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceIdValue,

        [Parameter(Mandatory)]
        [string]$SharedKey,

        [Parameter(Mandatory)]
        [string]$Rfc1123Date,

        [Parameter(Mandatory)]
        [string]$Payload
    )

    $contentLength = [System.Text.Encoding]::UTF8.GetByteCount($Payload)
    $stringToHash = "POST`n$contentLength`napplication/json`nx-ms-date:$Rfc1123Date`n/api/logs"
    $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($SharedKey)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)

    try {
        $hashBytes = $hmac.ComputeHash($bytesToHash)
    }
    finally {
        $hmac.Dispose()
    }

    $signature = [Convert]::ToBase64String($hashBytes)
    return 'SharedKey {0}:{1}' -f $WorkspaceIdValue, $signature
}

function Invoke-DcrIngestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestUri,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$Payload
    )

    if (-not $Context.ContainsKey('Token') -or [string]::IsNullOrWhiteSpace([string]$Context.Token)) {
        throw 'AuthContext.Token is required for the DCR-based Logs Ingestion API attempt.'
    }

    return Invoke-RestMethod -Method 'POST' -Uri $RequestUri -Headers @{ Authorization = "Bearer $($Context.Token)" } -ContentType 'application/json' -Body $Payload
}

function Invoke-DataCollectorIngestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceIdValue,

        [Parameter(Mandatory)]
        [string]$SharedKey,

        [Parameter(Mandatory)]
        [string]$LogType,

        [Parameter(Mandatory)]
        [string]$Payload,

        [Parameter(Mandatory)]
        [string]$Environment
    )

    $rfc1123Date = [DateTime]::UtcNow.ToString('r')
    $authorizationHeader = New-DataCollectorAuthorizationHeader -WorkspaceIdValue $WorkspaceIdValue -SharedKey $SharedKey -Rfc1123Date $rfc1123Date -Payload $Payload
    $dataCollectorHostSuffix = Get-DataCollectorHostSuffix -Environment $Environment
    $requestUri = 'https://{0}.{1}/api/logs?api-version=2016-04-01-jsonlines' -f $WorkspaceIdValue, $dataCollectorHostSuffix

    return Invoke-RestMethod -Method 'POST' -Uri $requestUri -Headers @{
        Authorization = $authorizationHeader
        'Log-Type' = $LogType
        'x-ms-date' = $rfc1123Date
    } -ContentType 'application/json' -Body $Payload
}

try {
    $environment = Get-AuthEnvironment -Context $AuthContext
    $resolvedDcrAuthContext = Resolve-DcrAuthContext -Context $AuthContext
    $jsonArrayPayload = $Data | ConvertTo-Json -Depth 20
    $dcrRequestUri = Resolve-DcrRequestUri -RawDceUri $DceUri -Environment $environment -ImmutableId $DcrImmutableId -TargetStreamName $StreamName

    try {
        $null = Invoke-DcrIngestion -RequestUri $dcrRequestUri -Context $resolvedDcrAuthContext -Payload $jsonArrayPayload
        return [ordered]@{
            Success = $true
            PathUsed = 'DcrLogsIngestionApi'
            DcrRequestUri = $dcrRequestUri
            WorkspaceId = $WorkspaceId
            StreamName = $StreamName
        }
    }
    catch {
        $dcrStatusCode = Get-HttpStatusCodeFromException -ErrorRecord $_
        $dcrErrorBody = Get-ResponseContentFromException -ErrorRecord $_

        if ($dcrStatusCode -ne 401 -and $dcrStatusCode -ne 403) {
            $message = if ([string]::IsNullOrWhiteSpace($dcrErrorBody)) {
                "DCR ingestion failed with HTTP $dcrStatusCode."
            }
            else {
                "DCR ingestion failed with HTTP $dcrStatusCode. $dcrErrorBody"
            }

            throw [System.InvalidOperationException]::new($message, $_.Exception)
        }

        Write-Warning 'DCR-based Logs Ingestion API returned 401 or 403. Attempting HTTP Data Collector API fallback.'

        if ([string]::IsNullOrWhiteSpace($WorkspaceSharedKey)) {
            $message = 'DCR-based Logs Ingestion API failed with HTTP {0} and no WorkspaceSharedKey was provided for Data Collector API fallback. DCR error details: {1}' -f $dcrStatusCode, $dcrErrorBody
            throw [System.InvalidOperationException]::new($message, $_.Exception)
        }

        $jsonLinesPayload = ConvertTo-JsonLines -Records $Data
        $logType = if (-not [string]::IsNullOrWhiteSpace($DataCollectorLogType)) { $DataCollectorLogType } else { Get-DataCollectorLogType -InputName $StreamName }

        try {
            $null = Invoke-DataCollectorIngestion -WorkspaceIdValue $WorkspaceId -SharedKey $WorkspaceSharedKey -LogType $logType -Payload $jsonLinesPayload -Environment $environment

            return [ordered]@{
                Success = $true
                PathUsed = 'HttpDataCollectorApi'
                DcrRequestUri = $dcrRequestUri
                WorkspaceId = $WorkspaceId
                StreamName = $StreamName
                LogType = $logType
                FallbackReason = 'DcrUnauthorized'
                DcrStatusCode = $dcrStatusCode
                DcrErrorBody = $dcrErrorBody
            }
        }
        catch {
            $fallbackStatusCode = Get-HttpStatusCodeFromException -ErrorRecord $_
            $fallbackErrorBody = Get-ResponseContentFromException -ErrorRecord $_
            $combinedMessage = 'DCR-based Logs Ingestion API failed with HTTP {0}. {1} The HTTP Data Collector API fallback also failed{2}{3}' -f `
                $dcrStatusCode,
                $dcrErrorBody,
                $(if ($null -ne $fallbackStatusCode) { ' with HTTP {0}' -f $fallbackStatusCode } else { '' }),
                $(if ([string]::IsNullOrWhiteSpace($fallbackErrorBody)) { '.' } else { ". $fallbackErrorBody" })

            throw [System.InvalidOperationException]::new($combinedMessage, $_.Exception)
        }
    }
}
catch {
    $message = "Failed to send Log Analytics data. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

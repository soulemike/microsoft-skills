#Requires -Version 7.2
<#
.SYNOPSIS
    Shared utilities for Microsoft Cloud API Skills.

.DESCRIPTION
    Common functions used across all skill domains:
    - Authentication context resolution
    - REST request execution with retry, throttling, and pagination
    - Endpoint resolution based on Azure environment
    - Structured error handling

    Import this module in skill scripts:
    . $PSScriptRoot/../Common.ps1
#>

$script:ModuleVersion = "1.0.0"
$script:DefaultRetryCount = 3
$script:DefaultRetryDelaySec = 2

# ---------------------------------------------------------------------------
# Endpoint Resolution
# ---------------------------------------------------------------------------
function Get-EnvironmentEndpoints {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Environment)

    switch ($Environment) {
        "AzureCloud" {
            return @{
                Graph = "https://graph.microsoft.com"
                Arm = "https://management.azure.com"
                DataverseGds = "https://globaldisco.crm.dynamics.com"
                Bap = "https://api.bap.microsoft.com"
                # Request endpoint for Log Analytics KQL queries and data-plane operations
                LogAnalytics = "https://api.loganalytics.azure.com"
                # Token audience for Log Analytics data-plane APIs (differs from request endpoint)
                LogAnalyticsTokenAudience = "https://api.loganalytics.io/"
                SentinelArm = "https://management.azure.com"
            }
        }
        "AzureUSGovernment" {
            return @{
                Graph = "https://graph.microsoft.us"
                Arm = "https://management.usgovcloudapi.net"
                DataverseGds = "https://globaldisco.crm9.dynamics.com"
                Bap = "https://api.bap.microsoft.us"
                LogAnalytics = "https://api.loganalytics.us"
                LogAnalyticsTokenAudience = "https://api.loganalytics.us/"
                SentinelArm = "https://management.usgovcloudapi.net"
            }
        }
        "AzureChinaCloud" {
            return @{
                Graph = "https://microsoftgraph.chinacloudapi.cn"
                Arm = "https://management.chinacloudapi.cn"
                DataverseGds = "https://globaldisco.crm.dynamics.cn"
                Bap = "https://api.bap.microsoft.cn"
                LogAnalytics = "https://api.loganalytics.azure.cn"
                LogAnalyticsTokenAudience = "https://api.loganalytics.azure.cn/"
                SentinelArm = "https://management.chinacloudapi.cn"
            }
        }
        default {
            throw "Unknown Azure environment: $Environment. Valid values: AzureCloud, AzureUSGovernment, AzureChinaCloud"
        }
    }
}

# ---------------------------------------------------------------------------
# Authentication Context Resolution
# ---------------------------------------------------------------------------
function Resolve-AuthContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$AuthContext,

        [Parameter()]
        [string]$AuthenticationType,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [SecureString]$ClientSecret,

        [Parameter()]
        [string]$CertificatePath,

        [Parameter()]
        [string]$FederatedToken,

        [Parameter()]
        [switch]$UseManagedIdentity,

        [Parameter()]
        [string]$Resource = "https://management.azure.com/"
    )

    # If an auth context object was passed, use it directly
    if ($AuthContext -and $AuthContext.Token) {
        return $AuthContext
    }

    # Resolve authentication type
    $authType = $AuthenticationType
    if (-not $authType -and $UseManagedIdentity) {
        $authType = "ManagedIdentity"
    }
    if (-not $authType) {
        throw [System.InvalidOperationException]::new(
            "No authentication type specified. Use -AuthenticationType, -UseManagedIdentity, or provide a pre-resolved -AuthContext. " +
            "To auto-detect the best available method, run ./prerequisites/Setup-AuthenticationContext.ps1 first."
        )
    }

    # Build context based on explicit parameters
    $context = @{
        Method = $authType
        Resource = $Resource
        TenantId = $TenantId
        ClientId = $ClientId
    }

    switch ($authType) {
        "ManagedIdentity" {
            $context.Token = (Get-ManagedIdentityToken -Resource $Resource)
        }
        "Federated" {
            if (-not $FederatedToken) { throw "FederatedToken is required for Federated authentication." }
            $exchange = Exchange-FederatedToken -OidcToken $FederatedToken -Resource $Resource -TenantId $TenantId -ClientId $ClientId
            $context.Token = $exchange.Token
            $context.ExpiresOn = $exchange.ExpiresOn
        }
        "Certificate" {
            if (-not $CertificatePath) { throw "CertificatePath is required for Certificate authentication." }
            $token = Get-CertificateToken -Resource $Resource -TenantId $TenantId -ClientId $ClientId -CertificatePath $CertificatePath
            $context.Token = $token.Token
            $context.ExpiresOn = $token.ExpiresOn
        }
        "ClientCredentials" {
            if (-not $ClientSecret) { throw "ClientSecret is required for ClientCredentials authentication." }
            Write-Warning "Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it."
            $token = Get-ClientCredentialToken -Resource $Resource -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
            $context.Token = $token.Token
            $context.ExpiresOn = $token.ExpiresOn
        }
        default {
            throw "Unknown authentication type: $authType"
        }
    }

    return $context
}

# ---------------------------------------------------------------------------
# Token Acquisition Helpers
# ---------------------------------------------------------------------------
function Get-ManagedIdentityToken {
    [CmdletBinding()]
    param([string]$Resource)

    $encodedResource = [System.Web.HttpUtility]::UrlEncode($Resource)

    # App Service / Functions
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $response = Invoke-RestMethod -Method GET `
            -Uri "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01" `
            -Headers @{
                "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER
                Metadata = "true"
            }
        return $response.access_token
    }

    # Azure Arc
    if ($env:IMDS_ENDPOINT -eq "http://localhost:40342" -or $env:IDENTITY_ENDPOINT -like "http://localhost:40342/*") {
        $endpoint = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2020-06-01"
        try {
            Invoke-WebRequest -Method GET -Uri $endpoint -Headers @{ Metadata = "True" } -UseBasicParsing | Out-Null
        }
        catch {
            $wwwAuth = $_.Exception.Response.Headers["WWW-Authenticate"]
            if ($wwwAuth -match "Basic realm=(.+)") {
                $secretFile = $Matches[1]
                $secret = Get-Content -Raw $secretFile
                $response = Invoke-RestMethod -Method GET -Uri $endpoint -Headers @{
                    Metadata = "True"
                    Authorization = "Basic $secret"
                }
                return $response.access_token
            }
        }
    }

    # Azure VM IMDS
    $response = Invoke-RestMethod -Method GET -TimeoutSec 5 -NoProxy `
        -Headers @{ Metadata = "true" } `
        -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource"
    return $response.access_token
}

function Exchange-FederatedToken {
    [CmdletBinding()]
    param([string]$OidcToken, [string]$Resource, [string]$TenantId, [string]$ClientId)

    $body = @{
        client_id = $ClientId
        scope = "$Resource/.default"
        grant_type = "client_credentials"
        client_assertion = $OidcToken
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    }

    $response = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    return @{
        Token = $response.access_token
        ExpiresOn = (Get-Date).AddSeconds($response.expires_in)
    }
}

function Get-CertificateToken {
    [CmdletBinding()]
    param([string]$Resource, [string]$TenantId, [string]$ClientId, [string]$CertificatePath)

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    $msal = Get-Module -ListAvailable -Name MSAL.PS
    if ($msal) {
        Import-Module MSAL.PS
        $token = Get-MsalToken -ClientId $ClientId -TenantId $TenantId -ClientCertificate $cert -Scopes "$Resource/.default"
        return @{ Token = $token.AccessToken; ExpiresOn = $token.ExpiresOn }
    }

    # Fallback via az cli
    az login --service-principal --username $ClientId --certificate $CertificatePath --tenant $TenantId --output none 2>$null
    $tokenJson = az account get-access-token --resource $Resource --output json | ConvertFrom-Json
    return @{ Token = $tokenJson.accessToken; ExpiresOn = Get-Date -Date $tokenJson.expiresOn }
}

function Get-ClientCredentialToken {
    [CmdletBinding()]
    param([string]$Resource, [string]$TenantId, [string]$ClientId, [SecureString]$ClientSecret)

    $body = @{
        client_id = $ClientId
        client_secret = ($ClientSecret | ConvertFrom-SecureString -AsPlainText)
        scope = "$Resource/.default"
        grant_type = "client_credentials"
    }

    $response = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    return @{
        Token = $response.access_token
        ExpiresOn = (Get-Date).AddSeconds($response.expires_in)
    }
}

# ---------------------------------------------------------------------------
# REST Request Execution with Retry and Throttling
# ---------------------------------------------------------------------------
function Invoke-SkillRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$AuthContext,
        [string]$Method = "GET",
        [object]$Body,
        [string]$ContentType = "application/json",
        [hashtable]$AdditionalHeaders = @{},
        [int]$RetryCount = $script:DefaultRetryCount,
        [int]$RetryDelaySec = $script:DefaultRetryDelaySec
    )

    $headers = @{
        Authorization = "Bearer $($AuthContext.Token)"
        "Content-Type" = $ContentType
    }
    foreach ($key in $AdditionalHeaders.Keys) {
        $headers[$key] = $AdditionalHeaders[$key]
    }

    $invokeParams = @{
        Uri = $Uri
        Method = $Method
        Headers = $headers
    }
    if ($Body) {
        if ($Body -is [hashtable] -or $Body -is [System.Collections.Specialized.OrderedDictionary]) {
            $invokeParams.Body = ($Body | ConvertTo-Json -Depth 10)
        }
        else {
            $invokeParams.Body = $Body
        }
    }

    $attempt = 0
    while ($attempt -le $RetryCount) {
        try {
            $response = Invoke-RestMethod @invokeParams
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response?.StatusCode.value__
            $retryAfter = if ($_.Exception.Response -and $_.Exception.Response.Headers) {
                $_.Exception.Response.Headers['Retry-After']
            }
            else {
                $null
            }

            # Throttling (429) or transient errors (5xx)
            if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                $attempt++
                if ($attempt -gt $RetryCount) { throw }

                $delay = if ($retryAfter) { [int]$retryAfter } else { $RetryDelaySec * [math]::Pow(2, $attempt - 1) }
                Write-Warning "Request throttled/transient failure (HTTP $statusCode). Retrying in ${delay}s... (attempt $attempt/$RetryCount)"
                Start-Sleep -Seconds $delay
                continue
            }

            # Auth expiration (401)
            if ($statusCode -eq 401) {
                throw "Authentication token expired or invalid (HTTP 401). Please re-authenticate."
            }

            throw
        }
    }
}

# ---------------------------------------------------------------------------
# Pagination Helper
# ---------------------------------------------------------------------------
function Get-PaginatedResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$AuthContext,
        [string]$NextLinkProperty = "@odata.nextLink",
        [string]$ValueProperty = "value"
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-SkillRestMethod -Uri $nextUri -AuthContext $AuthContext

        $value = if ($response -and $response.PSObject.Properties[$ValueProperty]) {
            $response.PSObject.Properties[$ValueProperty].Value
        }
        else {
            $null
        }

        if ($null -ne $value) {
            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                foreach ($item in $value) {
                    $results.Add($item)
                }
            }
            else {
                $results.Add($value)
            }
        }

        $nextUri = if ($response -and $response.PSObject.Properties[$NextLinkProperty]) {
            [string]$response.PSObject.Properties[$NextLinkProperty].Value
        }
        else {
            $null
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Environment File Loading
# ---------------------------------------------------------------------------
function Load-DotEnv {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = '.env'
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Verbose "Environment file '$Path' not found. Skipping."
        return
    }

    $lines = Get-Content -Path $Path
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^([^=]+)=(.*)$') {
            $name = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            # Remove quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }

    Write-Verbose "Loaded environment variables from '$Path'."
}

# ---------------------------------------------------------------------------
# Multi-Tenant Configuration Helpers
# ---------------------------------------------------------------------------
function Get-ProfileSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Configuration file '$Path' was not found."
    }

    $lines = Get-Content -Path $Path -ErrorAction Stop
    $inEnvironmentsBlock = $false
    $inRequestedProfile = $false
    $profileIndent = 0
    $settings = [ordered]@{}

    foreach ($rawLine in $lines) {
        $line = $rawLine
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) {
            continue
        }

        $indent = $line.Length - $line.TrimStart().Length

        if (-not $inEnvironmentsBlock) {
            if ($trimmed -eq 'environments:') {
                $inEnvironmentsBlock = $true
            }
            continue
        }

        if ($indent -eq 0 -and $trimmed -ne 'environments:') {
            break
        }

        if ($indent -eq 2 -and $trimmed -match '^(?<name>[^:#]+):\s*$') {
            $currentProfile = $Matches.name.Trim()
            $inRequestedProfile = $currentProfile -eq $ProfileName
            $profileIndent = $indent
            continue
        }

        if (-not $inRequestedProfile) {
            continue
        }

        if ($indent -le $profileIndent) {
            break
        }

        if ($indent -eq 4 -and $trimmed -match '^(?<key>[^:#]+):\s*(?<value>.*)$') {
            $key = $Matches.key.Trim()
            $value = $Matches.value.Trim()

            if ($value.StartsWith('#')) {
                $value = ''
            }
            if ($value -match '\s+#') {
                $value = ($value -replace '\s+#.*$', '').Trim()
            }
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            $settings[$key] = $value
        }
    }

    if ($settings.Count -eq 0) {
        throw "Profile '$ProfileName' was not found in '$Path'."
    }

    return $settings
}

function Get-PrefixedEnvironmentVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,

        [Parameter()]
        [string]$Prefix
    )

    $candidateNames = [System.Collections.Generic.List[string]]::new()
    if ($Prefix) {
        $normalizedPrefix = $Prefix.Trim().TrimEnd('_').ToUpperInvariant()
        foreach ($name in $Names) {
            $candidateNames.Add("${normalizedPrefix}_${name}")
        }
    }

    foreach ($name in $Names) {
        $candidateNames.Add($name)
    }

    foreach ($candidateName in $candidateNames) {
        $value = [Environment]::GetEnvironmentVariable($candidateName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Name = $candidateName; Value = $value }
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Export module members
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    "Get-EnvironmentEndpoints"
    "Resolve-AuthContext"
    "Get-ManagedIdentityToken"
    "Exchange-FederatedToken"
    "Get-CertificateToken"
    "Get-ClientCredentialToken"
    "Invoke-SkillRestMethod"
    "Get-PaginatedResults"
    "Load-DotEnv"
    "Get-ProfileSettings"
    "Get-PrefixedEnvironmentVariable"
)

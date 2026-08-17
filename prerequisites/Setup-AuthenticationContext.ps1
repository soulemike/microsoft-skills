#Requires -Version 7.2
<#
.SYNOPSIS
    Guided authentication setup for Microsoft Cloud API Skills.

.DESCRIPTION
    Probes the execution environment and selects the highest-trust authentication
    method available. Implements a deterministic fallback chain:
    1. Managed Identity (Azure VM IMDS, App Service/Functions local endpoint, Azure Arc HIMDS)
    2. Federated Credentials (GitHub Actions, Azure DevOps, GitLab CI OIDC)
    3. Certificate-Based Authentication
    4. Client Credentials (with mandatory warning)

    The script normalizes environment variables and returns a context object
    that can be consumed by Connect-* functions across all skill domains.

.EXAMPLE
    $authContext = ./prerequisites/Setup-AuthenticationContext.ps1 -Resource "https://management.azure.com/"
    Connect-GraphApi -AuthContext $authContext -Environment AzureCloud
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Resource = "https://management.azure.com/",

    [Parameter()]
    [string]$TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string]$ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,

    [Parameter()]
    [string]$CertificatePath = $env:AZURE_CLIENT_CERTIFICATE_PATH,

    [Parameter()]
    [string]$FederatedToken = $env:AZURE_FEDERATED_TOKEN,

    [Parameter()]
    [switch]$SuppressWarning
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Normalized variable resolution
# ---------------------------------------------------------------------------
$script:ResolvedTenantId = $TenantId ?? $env:ARM_TENANT_ID ?? $env:TENANT_ID
$script:ResolvedClientId = $ClientId ?? $env:ARM_CLIENT_ID ?? $env:CLIENT_ID
$script:ResolvedClientSecret = $ClientSecret ?? $env:ARM_CLIENT_SECRET ?? $env:CLIENT_SECRET
$script:ResolvedCertificatePath = $CertificatePath ?? $env:ARM_CLIENT_CERTIFICATE_PATH
$script:ResolvedFederatedToken = $FederatedToken

# ---------------------------------------------------------------------------
# Helper: Write-AuthLog
# ---------------------------------------------------------------------------
function Write-AuthLog {
    param([string]$Message, [string]$Level = "Info")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "Warning" { Write-Warning "[$ts] $Message" }
        "Error"   { Write-Error "[$ts] $Message" }
        default   { Write-Host "[$ts] $Message" }
    }
}

# ---------------------------------------------------------------------------
# Detection: Managed Identity
# ---------------------------------------------------------------------------
function Test-ManagedIdentity {
    [CmdletBinding()]
    param([string]$ResourceUri)

    # Azure Arc detection
    if ($env:IMDS_ENDPOINT -eq "http://localhost:40342" -or
        $env:IDENTITY_ENDPOINT -like "http://localhost:40342/*") {
        Write-AuthLog "Azure Arc HIMDS endpoint detected" "Info"
        try {
            $endpoint = "$($env:IDENTITY_ENDPOINT)?resource=$ResourceUri&api-version=2020-06-01"
            Invoke-WebRequest -Method GET -Uri $endpoint -Headers @{ Metadata = "True" } -UseBasicParsing | Out-Null
        }
        catch {
            $wwwAuth = $_.Exception.Response.Headers["WWW-Authenticate"]
            if ($wwwAuth -match "Basic realm=(.+)") {
                $secretFile = $Matches[1]
                if (Test-Path $secretFile) {
                    $secret = Get-Content -Raw $secretFile
                    $response = Invoke-RestMethod -Method GET -Uri $endpoint -Headers @{
                        Metadata = "True"
                        Authorization = "Basic $secret"
                    }
                    if ($response.access_token) {
                        return @{ Method = "ManagedIdentity"; SubMethod = "AzureArc"; Token = $response.access_token }
                    }
                }
            }
        }
    }

    # App Service / Functions / Automation local endpoint
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        Write-AuthLog "App Service/Functions managed identity endpoint detected" "Info"
        try {
            $response = Invoke-RestMethod -Method GET `
                -Uri "$($env:IDENTITY_ENDPOINT)?resource=$ResourceUri&api-version=2019-08-01" `
                -Headers @{
                    "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER
                    Metadata = "true"
                }
            if ($response.access_token) {
                return @{ Method = "ManagedIdentity"; SubMethod = "AppService"; Token = $response.access_token }
            }
        }
        catch {
            Write-AuthLog "App Service MI probe failed: $($_.Exception.Message)" "Warning"
        }
    }

    # Azure VM / VMSS IMDS
    Write-AuthLog "Probing Azure VM IMDS endpoint..." "Info"
    try {
        $encodedResource = [System.Web.HttpUtility]::UrlEncode($ResourceUri)
        $response = Invoke-RestMethod -Method GET -TimeoutSec 2 -NoProxy `
            -Headers @{ Metadata = "true" } `
            -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource"
        if ($response.access_token) {
            return @{ Method = "ManagedIdentity"; SubMethod = "IMDS"; Token = $response.access_token }
        }
    }
    catch {
        Write-AuthLog "IMDS probe failed: $($_.Exception.Message)" "Warning"
    }

    return $null
}

# ---------------------------------------------------------------------------
# Detection: Federated Credentials
# ---------------------------------------------------------------------------
function Test-FederatedCredential {
    [CmdletBinding()]
    param([string]$ResourceUri)

    # GitHub Actions
    if ($env:GITHUB_ACTIONS -eq "true" -and
        $env:ACTIONS_ID_TOKEN_REQUEST_URL -and
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
        Write-AuthLog "GitHub Actions OIDC detected" "Info"
        try {
            $oidcResponse = Invoke-RestMethod -Method GET `
                -Uri "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange" `
                -Headers @{ Authorization = "bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }
            $oidcToken = $oidcResponse.value
            if ($oidcToken) {
                return Exchange-OidcToken -OidcToken $oidcToken -ResourceUri $ResourceUri
            }
        }
        catch {
            Write-AuthLog "GitHub Actions OIDC exchange failed: $($_.Exception.Message)" "Warning"
        }
    }

    # Azure DevOps
    if ($env:SYSTEM_OIDCREQUESTURI -and $env:SYSTEM_ACCESSTOKEN) {
        Write-AuthLog "Azure DevOps OIDC detected" "Info"
        try {
            $uri = "$($env:SYSTEM_OIDCREQUESTURI)?api-version=7.1"
            if ($env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID) {
                $uri += "&serviceConnectionId=$($env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID)"
            }
            $oidcResponse = Invoke-RestMethod -Method POST -Uri $uri `
                -Headers @{
                    Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)"
                    "Content-Type" = "application/json"
                }
            $oidcToken = $oidcResponse.oidcToken
            if ($oidcToken) {
                return Exchange-OidcToken -OidcToken $oidcToken -ResourceUri $ResourceUri
            }
        }
        catch {
            Write-AuthLog "Azure DevOps OIDC exchange failed: $($_.Exception.Message)" "Warning"
        }
    }

    # GitLab CI/CD
    if ($env:GITLAB_CI -eq "true" -and $env:AZURE_FEDERATED_TOKEN) {
        Write-AuthLog "GitLab CI/CD OIDC detected" "Info"
        try {
            return Exchange-OidcToken -OidcToken $env:AZURE_FEDERATED_TOKEN -ResourceUri $ResourceUri
        }
        catch {
            Write-AuthLog "GitLab OIDC exchange failed: $($_.Exception.Message)" "Warning"
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Helper: Exchange OIDC token for Entra access token
# ---------------------------------------------------------------------------
function Exchange-OidcToken {
    [CmdletBinding()]
    param([string]$OidcToken, [string]$ResourceUri)

    if (-not $script:ResolvedClientId -or -not $script:ResolvedTenantId) {
        throw "ClientId and TenantId are required for federated credential authentication."
    }

    $scope = "$ResourceUri/.default"
    $body = @{
        client_id = $script:ResolvedClientId
        scope = $scope
        grant_type = "client_credentials"
        client_assertion = $OidcToken
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    }

    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$($script:ResolvedTenantId)/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    return @{
        Method = "Federated"
        Token = $tokenResponse.access_token
        ExpiresOn = (Get-Date).AddSeconds($tokenResponse.expires_in)
    }
}

# ---------------------------------------------------------------------------
# Detection: Certificate
# ---------------------------------------------------------------------------
function Test-CertificateAuth {
    [CmdletBinding()]
    param([string]$ResourceUri)

    if (-not $script:ResolvedCertificatePath) { return $null }
    if (-not $script:ResolvedClientId -or -not $script:ResolvedTenantId) {
        throw "ClientId and TenantId are required for certificate authentication."
    }

    Write-AuthLog "Attempting certificate-based authentication..." "Info"
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($script:ResolvedCertificatePath)
        $scope = "$ResourceUri/.default"

        # Use MSAL.NET if available, otherwise fall back to az cli
        $msal = Get-Module -ListAvailable -Name MSAL.PS
        if ($msal) {
            Import-Module MSAL.PS
            $token = Get-MsalToken -ClientId $script:ResolvedClientId `
                -TenantId $script:ResolvedTenantId `
                -ClientCertificate $cert `
                -Scopes $scope
            return @{
                Method = "Certificate"
                Token = $token.AccessToken
                ExpiresOn = $token.ExpiresOn
            }
        }
        else {
            # Fallback to az login + az account get-access-token
            $azLogin = az login --service-principal `
                --username $script:ResolvedClientId `
                --certificate $script:ResolvedCertificatePath `
                --tenant $script:ResolvedTenantId `
                --output none 2>&1
            if ($LASTEXITCODE -ne 0) { throw "az login failed: $azLogin" }

            $tokenJson = az account get-access-token --resource $ResourceUri --output json | ConvertFrom-Json
            return @{
                Method = "Certificate"
                Token = $tokenJson.accessToken
                ExpiresOn = Get-Date -Date $tokenJson.expiresOn
            }
        }
    }
    catch {
        Write-AuthLog "Certificate authentication failed: $($_.Exception.Message)" "Warning"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Detection: Client Credentials (last resort)
# ---------------------------------------------------------------------------
function Test-ClientCredential {
    [CmdletBinding()]
    param([string]$ResourceUri)

    if (-not $script:ResolvedClientSecret) { return $null }
    if (-not $script:ResolvedClientId -or -not $script:ResolvedTenantId) {
        throw "ClientId and TenantId are required for client credential authentication."
    }

    if (-not $SuppressWarning) {
        Write-Warning "Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it."
    }

    Write-AuthLog "Falling back to client credential authentication..." "Warning"
    try {
        $body = @{
            client_id = $script:ResolvedClientId
            client_secret = $script:ResolvedClientSecret
            scope = "$ResourceUri/.default"
            grant_type = "client_credentials"
        }

        $tokenResponse = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$($script:ResolvedTenantId)/oauth2/v2.0/token" `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $body

        return @{
            Method = "ClientCredentials"
            Token = $tokenResponse.access_token
            ExpiresOn = (Get-Date).AddSeconds($tokenResponse.expires_in)
        }
    }
    catch {
        Write-AuthLog "Client credential authentication failed: $($_.Exception.Message)" "Error"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Main: Execute fallback chain
# ---------------------------------------------------------------------------
Write-AuthLog "Starting authentication context detection..." "Info"

$authContext = $null

# 1. Managed Identity
$authContext = Test-ManagedIdentity -ResourceUri $Resource

# 2. Federated Credentials
if (-not $authContext) {
    $authContext = Test-FederatedCredential -ResourceUri $Resource
}

# 3. Certificate
if (-not $authContext) {
    $authContext = Test-CertificateAuth -ResourceUri $Resource
}

# 4. Client Credentials (last resort)
if (-not $authContext) {
    $authContext = Test-ClientCredential -ResourceUri $Resource
}

if (-not $authContext) {
    throw "No usable Azure authentication method found. Please configure managed identity, federated credentials, certificate auth, or client credentials. See agents.md for setup guidance."
}

# Enrich context
$authContext.TenantId = $script:ResolvedTenantId
$authContext.ClientId = $script:ResolvedClientId
$authContext.Resource = $Resource
$authContext.AcquiredAt = Get-Date

Write-AuthLog "Authentication successful using method: $($authContext.Method)" "Info"

# Return context object
return $authContext

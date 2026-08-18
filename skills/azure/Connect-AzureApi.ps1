#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes an Azure Resource Manager authentication context.

.DESCRIPTION
    Resolves Azure Resource Manager endpoints for the selected Azure environment,
    acquires an access token using the normalized authentication parameter set,
    and returns a consistent ARM context object for downstream skill scripts.

    Supported authentication methods:
    - Managed Identity
    - Federated credentials
    - Certificate-based service principal
    - Client credentials (client secret, with mandatory warning)

    A pre-resolved authentication context may be supplied via -AuthContext.

.PARAMETER AuthenticationType
    Authentication method to use. Valid values are ManagedIdentity, Federated,
    Certificate, and ClientCredentials.

.PARAMETER TenantId
    Microsoft Entra tenant ID. Required for Federated, Certificate, and
    ClientCredentials authentication.

.PARAMETER ClientId
    Application (client) ID. Required for Federated, Certificate, and
    ClientCredentials authentication. Optional for ManagedIdentity and used when
    targeting a user-assigned managed identity.

.PARAMETER ClientSecret
    Secure client secret for ClientCredentials authentication.

.PARAMETER CertificatePath
    Path to the PFX certificate used for Certificate authentication.

.PARAMETER FederatedToken
    OIDC token used for Federated authentication.

.PARAMETER UseManagedIdentity
    Alias switch for -AuthenticationType ManagedIdentity.

.PARAMETER Environment
    Azure cloud environment. Valid values are AzureCloud,
    AzureUSGovernment, and AzureChinaCloud.

.PARAMETER SubscriptionId
    Optional Azure subscription ID to attach to the returned context.

    .PARAMETER AuthContext
    Pre-resolved authentication context hashtable. When provided, token values
    from this context are reused and enriched with ARM endpoint metadata.

    .PARAMETER Prefix
    Optional environment variable prefix for multi-tenant configuration.

    .PARAMETER Profile
    Optional named profile under config.yaml.

    .PARAMETER ConfigPath
    Optional path to a configuration file. Defaults to repository root config.yaml.

    .OUTPUTS
    PSCustomObject

    .EXAMPLE
    ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

    .EXAMPLE
    ./skills/azure/Connect-AzureApi.ps1 -AuthenticationType ClientCredentials -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -ClientSecret $secret -Environment AzureCloud -SubscriptionId $env:AZURE_SUBSCRIPTION_ID

    .EXAMPLE
    ./skills/azure/Connect-AzureApi.ps1 -Profile prod

    .EXAMPLE
    ./skills/azure/Connect-AzureApi.ps1 -Prefix GOV -UseManagedIdentity -Environment AzureUSGovernment
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('ManagedIdentity', 'Federated', 'Certificate', 'ClientCredentials')]
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

    [Parameter(Mandatory)]
    [Alias('AzureEnvironment')]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [hashtable]$AuthContext,

    [Parameter()]
    [string]$Prefix,

    [Parameter()]
    [string]$Profile,

    [Parameter()]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot '..' 'Common.psm1'
Import-Module $commonModulePath -Force

# Resolve profile settings from config.yaml if -Profile is specified
if ($Profile) {
    $effectiveConfigPath = if ($ConfigPath) {
        [System.IO.Path]::GetFullPath($ConfigPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'config.yaml'))
    }

    $profileSettings = Get-ProfileSettings -ProfileName $Profile -Path $effectiveConfigPath
    $profileMap = @{
        AuthenticationType = 'authenticationType'
        TenantId = 'tenantId'
        ClientId = 'clientId'
        CertificatePath = 'certificatePath'
        Environment = 'azureEnvironment'
        SubscriptionId = 'subscriptionId'
    }

    foreach ($targetKey in $profileMap.Keys) {
        $currentValue = Get-Variable -Name $targetKey -ValueOnly -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace([string]$currentValue) -and $profileSettings.Contains($profileMap[$targetKey])) {
            $candidateValue = [string]$profileSettings[$profileMap[$targetKey]]
            if (-not [string]::IsNullOrWhiteSpace($candidateValue)) {
                Set-Variable -Name $targetKey -Value $candidateValue
            }
        }
    }

    if (-not $UseManagedIdentity -and $profileSettings.Contains('useManagedIdentity')) {
        $useManagedIdentityValue = $profileSettings.useManagedIdentity
        if ($useManagedIdentityValue -eq 'true' -or $useManagedIdentityValue -eq 'True') {
            $UseManagedIdentity = $true
        }
    }
}

# Resolve prefixed environment variables if -Prefix is specified
if ($Prefix) {
    $envVarMap = @{
        TenantId = @('AZURE_TENANT_ID', 'ARM_TENANT_ID', 'TENANT_ID')
        ClientId = @('AZURE_CLIENT_ID', 'ARM_CLIENT_ID', 'CLIENT_ID')
        ClientSecret = @('AZURE_CLIENT_SECRET', 'ARM_CLIENT_SECRET', 'CLIENT_SECRET')
        CertificatePath = @('AZURE_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PATH', 'CERTIFICATE_PATH')
        FederatedToken = @('AZURE_FEDERATED_TOKEN', 'FEDERATED_TOKEN')
        Environment = @('AZURE_ENVIRONMENT', 'AZURE_CLOUD_ENVIRONMENT', 'ENVIRONMENT')
        SubscriptionId = @('AZURE_SUBSCRIPTION_ID', 'ARM_SUBSCRIPTION_ID', 'SUBSCRIPTION_ID')
    }

    foreach ($varName in $envVarMap.Keys) {
        $currentValue = Get-Variable -Name $varName -ValueOnly -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace([string]$currentValue)) {
            $match = Get-PrefixedEnvironmentVariable -Names $envVarMap[$varName] -Prefix $Prefix
            if ($match) {
                if ($varName -eq 'ClientSecret') {
                    $secureString = [System.Security.SecureString]::new()
                    $match.Value.ToCharArray() | ForEach-Object { $secureString.AppendChar($_) }
                    Set-Variable -Name $varName -Value $secureString
                } else {
                    Set-Variable -Name $varName -Value $match.Value
                }
            }
        }
    }

    $prefixUseManagedIdentity = Get-PrefixedEnvironmentVariable -Names @('AZURE_USE_MANAGED_IDENTITY', 'USE_MANAGED_IDENTITY') -Prefix $Prefix
    if ($prefixUseManagedIdentity -and -not $UseManagedIdentity) {
        $useMiValue = $prefixUseManagedIdentity.Value
        if ($useMiValue -eq 'true' -or $useMiValue -eq 'True' -or $useMiValue -eq '1') {
            $UseManagedIdentity = $true
        }
    }
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

function ConvertTo-ExpiryDate {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [AllowNull()]
        [pscustomobject]$JwtClaims
    )

    if ($null -ne $Value) {
        if ($Value -is [datetime]) {
            return $Value
        }

        if ($Value -is [datetimeoffset]) {
            return $Value.UtcDateTime
        }

        if ($Value -is [string]) {
            $trimmed = $Value.Trim()
            if ($trimmed -match '^\d+$') {
                return [DateTimeOffset]::FromUnixTimeSeconds([int64]$trimmed).UtcDateTime
            }

            $parsedDate = [datetime]::MinValue
            if ([datetime]::TryParse($trimmed, [ref]$parsedDate)) {
                return $parsedDate
            }
        }

        if ($Value -is [int] -or $Value -is [long]) {
            return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value).UtcDateTime
        }
    }

    if ($JwtClaims -and $JwtClaims.PSObject.Properties.Name -contains 'exp') {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$JwtClaims.exp).UtcDateTime
    }

    return $null
}

function Resolve-AzureManagedIdentityContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'arcEndpoint', Justification = 'Variable is assigned in if/else and used later; PSSA cannot trace across conditional blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Resource,

        [Parameter()]
        [string]$ManagedIdentityClientId
    )

    $encodedResource = [System.Web.HttpUtility]::UrlEncode($Resource)

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $queryParts = @(
            "resource=$encodedResource"
            'api-version=2019-08-01'
        )

        if ($ManagedIdentityClientId) {
            $queryParts += "client_id=$([System.Web.HttpUtility]::UrlEncode($ManagedIdentityClientId))"
        }

        $response = Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?$($queryParts -join '&')" -Headers @{
            'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
            Metadata = 'true'
        }

        return @{
            Method = 'ManagedIdentity'
            Token = $response.access_token
            ExpiresOn = ConvertTo-ExpiryDate -Value $response.expires_on
            ClientId = $ManagedIdentityClientId
        }
    }

    if ($env:IMDS_ENDPOINT -eq 'http://localhost:40342' -or $env:IDENTITY_ENDPOINT -like 'http://localhost:40342/*') {
        if ($env:IDENTITY_ENDPOINT) {
            $arcEndpoint = $env:IDENTITY_ENDPOINT
        }
        else {
            $arcEndpoint = 'http://localhost:40342/metadata/identity/oauth2/token'
        }

        $queryParts = @(
            "resource=$encodedResource"
            'api-version=2020-06-01'
        )

        if ($ManagedIdentityClientId) {
            $queryParts += "client_id=$([System.Web.HttpUtility]::UrlEncode($ManagedIdentityClientId))"
        }

        $requestUri = "$arcEndpoint?$($queryParts -join '&')"

        try {
            $response = Invoke-RestMethod -Method GET -Uri $requestUri -Headers @{ Metadata = 'True' }
            return @{
                Method = 'ManagedIdentity'
                Token = $response.access_token
                ExpiresOn = ConvertTo-ExpiryDate -Value $response.expires_on
                ClientId = $ManagedIdentityClientId
            }
        }
        catch {
            $wwwAuthenticate = $_.Exception.Response?.Headers['WWW-Authenticate']
            if (-not $wwwAuthenticate -or $wwwAuthenticate -notmatch 'Basic realm=(.+)') {
                throw
            }

            $secretFile = $Matches[1].Trim('"')
            if (-not (Test-Path -Path $secretFile)) {
                throw "Azure Arc managed identity challenge file was not found: $secretFile"
            }

            $secret = Get-Content -Path $secretFile -Raw
            $response = Invoke-RestMethod -Method GET -Uri $requestUri -Headers @{
                Metadata = 'True'
                Authorization = "Basic $secret"
            }

            return @{
                Method = 'ManagedIdentity'
                Token = $response.access_token
                ExpiresOn = ConvertTo-ExpiryDate -Value $response.expires_on
                ClientId = $ManagedIdentityClientId
            }
        }
    }

    $queryParts = @(
        'api-version=2018-02-01'
        "resource=$encodedResource"
    )

    if ($ManagedIdentityClientId) {
        $queryParts += "client_id=$([System.Web.HttpUtility]::UrlEncode($ManagedIdentityClientId))"
    }

    $imdsUri = "http://169.254.169.254/metadata/identity/oauth2/token?$($queryParts -join '&')"
    $response = Invoke-RestMethod -Method GET -TimeoutSec 5 -NoProxy -Headers @{ Metadata = 'true' } -Uri $imdsUri

    return @{
        Method = 'ManagedIdentity'
        Token = $response.access_token
        ExpiresOn = ConvertTo-ExpiryDate -Value $response.expires_on
        ClientId = $ManagedIdentityClientId
    }
}

try {
    if ($UseManagedIdentity -and $AuthenticationType -and $AuthenticationType -ne 'ManagedIdentity') {
        throw 'When -UseManagedIdentity is specified, -AuthenticationType must be ManagedIdentity or omitted.'
    }

    $resolvedAuthType = if ($UseManagedIdentity -and -not $AuthenticationType) {
        'ManagedIdentity'
    }
    else {
        $AuthenticationType
    }

    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $armEndpoint = $endpoints.Arm.TrimEnd('/')

    $resolvedAuthContext = $null
    if ($AuthContext -and $AuthContext.Token) {
        if ($AuthContext.Method -eq 'ClientCredentials') {
            Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'
        }

        $resolvedAuthContext = @{} + $AuthContext
    }
    elseif ($resolvedAuthType -eq 'ManagedIdentity') {
        $resolvedAuthContext = Resolve-AzureManagedIdentityContext -Resource $armEndpoint -ManagedIdentityClientId $ClientId
        if ($TenantId) {
            $resolvedAuthContext.TenantId = $TenantId
        }
    }
    else {
        $resolvedAuthContext = Resolve-AuthContext -AuthenticationType $resolvedAuthType -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -CertificatePath $CertificatePath -FederatedToken $FederatedToken -UseManagedIdentity:$UseManagedIdentity -Resource $armEndpoint -AuthContext $AuthContext
    }

    if (-not $resolvedAuthContext -or -not $resolvedAuthContext.Token) {
        throw 'Failed to resolve an Azure ARM authentication context.'
    }

    $jwtClaims = Get-JwtClaims -Token $resolvedAuthContext.Token
    $effectiveTenantId = if ($TenantId) {
        $TenantId
    }
    elseif ($resolvedAuthContext.TenantId) {
        $resolvedAuthContext.TenantId
    }
    elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'tid') {
        [string]$jwtClaims.tid
    }
    else {
        $null
    }

    $effectiveClientId = if ($ClientId) {
        $ClientId
    }
    elseif ($resolvedAuthContext.ClientId) {
        $resolvedAuthContext.ClientId
    }
    elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'appid') {
        [string]$jwtClaims.appid
    }
    elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'azp') {
        [string]$jwtClaims.azp
    }
    else {
        $null
    }

    $context = @{
        Token = $resolvedAuthContext.Token
        ExpiresOn = ConvertTo-ExpiryDate -Value $resolvedAuthContext.ExpiresOn -JwtClaims $jwtClaims
        TenantId = $effectiveTenantId
        ClientId = $effectiveClientId
        SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $resolvedAuthContext.SubscriptionId }
        Environment = $Environment
        ArmEndpoint = $armEndpoint
        BaseUri = $armEndpoint
        AuthenticationType = if ($resolvedAuthContext.Method) { $resolvedAuthContext.Method } else { $resolvedAuthType }
    }

    return $context
}
catch {
    $message = "Failed to establish Azure ARM context. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

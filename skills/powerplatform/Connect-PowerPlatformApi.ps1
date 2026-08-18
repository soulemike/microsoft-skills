#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes a Power Platform Business Application Platform (BAP) API authentication context.

.DESCRIPTION
    Resolves the Power Platform BAP API endpoint for the selected Azure cloud,
    acquires an Azure Resource Manager-scoped access token using the project's
    normalized authentication parameters, and returns a consistent context
    hashtable for downstream Power Platform skill scripts.

    The script supports explicit parameters, prefixed environment variables, and
    named profiles from the repository configuration file to enable multi-tenant
    automation patterns.

.PARAMETER AuthenticationType
    Authentication method to use. Valid values are ManagedIdentity, Federated,
    Certificate, and ClientCredentials.

.PARAMETER TenantId
    Microsoft Entra tenant identifier. Required for Federated, Certificate, and
    ClientCredentials authentication.

.PARAMETER ClientId
    Application (client) identifier. Required for Federated, Certificate, and
    ClientCredentials authentication. Optional for ManagedIdentity and used when
    targeting a user-assigned managed identity.

.PARAMETER ClientSecret
    Secure client secret used only for ClientCredentials authentication.

.PARAMETER CertificatePath
    Path to the certificate file used for Certificate authentication.

.PARAMETER CertificatePassword
    Secure password for an encrypted certificate file. Included for normalized
    parameter compatibility.

.PARAMETER FederatedToken
    OIDC token used for Federated authentication.

.PARAMETER UseManagedIdentity
    Alias for -AuthenticationType ManagedIdentity.

.PARAMETER Environment
    Azure cloud environment used to resolve the BAP API endpoint. Valid values
    are AzureCloud, AzureUSGovernment, and AzureChinaCloud.

.PARAMETER Prefix
    Optional environment variable prefix for multi-tenant configuration. For
    example, -Prefix GOV resolves GOV_TENANT_ID, GOV_CLIENT_ID, and related
    variables.

.PARAMETER Profile
    Optional named profile under config.yaml. Explicit parameters override
    profile values when both are supplied.

.PARAMETER ConfigPath
    Optional path to a configuration file that contains named profiles. Defaults
    to the repository root config.yaml.

.PARAMETER AuthContext
    Optional pre-resolved authentication context returned from shared auth
    helpers or another Connect-* script.

.OUTPUTS
    Hashtable with Token, ExpiresOn, TenantId, ClientId, Environment, and
    BaseUri.

.EXAMPLE
    ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

.EXAMPLE
    ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -Profile prod

.EXAMPLE
    ./skills/powerplatform/Connect-PowerPlatformApi.ps1 -Prefix GOV -UseManagedIdentity -Environment AzureUSGovernment
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
    [securestring]$ClientSecret,

    [Parameter()]
    [string]$CertificatePath,

    [Parameter()]
    [securestring]$CertificatePassword,

    [Parameter()]
    [string]$FederatedToken,

    [Parameter()]
    [switch]$UseManagedIdentity,

    [Parameter()]
    [Alias('AzureEnvironment')]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Prefix,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Profile,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [object]$AuthContext
)

. $PSScriptRoot/../Common.psm1
if (-not (Get-Command -Name 'Get-EnvironmentEndpoints' -ErrorAction SilentlyContinue) -or -not (Get-Command -Name 'Resolve-AuthContext' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-DefaultConfigPath {
    [CmdletBinding()]
    param()

    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'config.yaml'))
}

function ConvertTo-NullableSecureString {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $secureString = [System.Security.SecureString]::new()
    $Value.ToCharArray() | ForEach-Object { $secureString.AppendChar($_) }
    return $secureString
}

function ConvertTo-BooleanValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    return $normalized -in @('1', 'true', 'yes', 'y', 'on')
}

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

function Get-EnvironmentVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,

        [Parameter()]
        [string]$VariablePrefix
    )

    $candidateNames = [System.Collections.Generic.List[string]]::new()
    if ($VariablePrefix) {
        $normalizedPrefix = $VariablePrefix.Trim().TrimEnd('_').ToUpperInvariant()
        foreach ($name in $Names) {
            $prefixedName = '{0}_{1}' -f $normalizedPrefix, $name
            $candidateNames.Add($prefixedName)
        }
    }

    foreach ($name in $Names) {
        $candidateNames.Add($name)
    }

    foreach ($candidateName in $candidateNames) {
        $value = [Environment]::GetEnvironmentVariable($candidateName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{
                Name = $candidateName
                Value = $value
            }
        }
    }

    return $null
}

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

function Resolve-ConnectionSettings {
    [CmdletBinding()]
    param()

    $resolved = [ordered]@{
        AuthenticationType = $AuthenticationType
        TenantId = $TenantId
        ClientId = $ClientId
        ClientSecret = $ClientSecret
        CertificatePath = $CertificatePath
        CertificatePassword = $CertificatePassword
        FederatedToken = $FederatedToken
        Environment = $Environment
        UseManagedIdentity = [bool]$UseManagedIdentity
    }

    if ($Profile) {
        $effectiveConfigPath = if ($ConfigPath) {
            [System.IO.Path]::GetFullPath($ConfigPath)
        }
        else {
            Get-DefaultConfigPath
        }

        $profileSettings = Get-ProfileSettings -ProfileName $Profile -Path $effectiveConfigPath
        $profileMap = @{
            AuthenticationType = 'authenticationType'
            TenantId = 'tenantId'
            ClientId = 'clientId'
            CertificatePath = 'certificatePath'
            Environment = 'azureEnvironment'
        }

        foreach ($targetKey in $profileMap.Keys) {
            if ([string]::IsNullOrWhiteSpace([string]$resolved[$targetKey]) -and $profileSettings.Contains($profileMap[$targetKey])) {
                $candidateValue = [string]$profileSettings[$profileMap[$targetKey]]
                if (-not [string]::IsNullOrWhiteSpace($candidateValue)) {
                    $resolved[$targetKey] = $candidateValue
                }
            }
        }

        if (-not $resolved.UseManagedIdentity -and $profileSettings.Contains('useManagedIdentity')) {
            $resolved.UseManagedIdentity = ConvertTo-BooleanValue -Value $profileSettings.useManagedIdentity
        }
    }

    $usedEnvironmentVariables = $false
    $usedNonSecretEnvironmentVariables = $false

    $environmentVariableMap = @(
        @{ Name = 'AuthenticationType'; Aliases = @('AZURE_AUTHENTICATION_TYPE', 'AUTHENTICATION_TYPE') ; IsSecret = $false },
        @{ Name = 'TenantId'; Aliases = @('AZURE_TENANT_ID', 'ARM_TENANT_ID', 'TENANT_ID') ; IsSecret = $false },
        @{ Name = 'ClientId'; Aliases = @('AZURE_CLIENT_ID', 'ARM_CLIENT_ID', 'CLIENT_ID') ; IsSecret = $false },
        @{ Name = 'ClientSecret'; Aliases = @('AZURE_CLIENT_SECRET', 'ARM_CLIENT_SECRET', 'CLIENT_SECRET') ; IsSecret = $true },
        @{ Name = 'CertificatePath'; Aliases = @('AZURE_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PATH', 'CERTIFICATE_PATH') ; IsSecret = $false },
        @{ Name = 'CertificatePassword'; Aliases = @('AZURE_CLIENT_CERTIFICATE_PASSWORD', 'ARM_CLIENT_CERTIFICATE_PASSWORD', 'CERTIFICATE_PASSWORD') ; IsSecret = $true },
        @{ Name = 'FederatedToken'; Aliases = @('AZURE_FEDERATED_TOKEN', 'FEDERATED_TOKEN') ; IsSecret = $true },
        @{ Name = 'Environment'; Aliases = @('AZURE_ENVIRONMENT', 'AZURE_CLOUD_ENVIRONMENT', 'ENVIRONMENT') ; IsSecret = $false },
        @{ Name = 'UseManagedIdentity'; Aliases = @('AZURE_USE_MANAGED_IDENTITY', 'USE_MANAGED_IDENTITY') ; IsSecret = $false }
    )

    foreach ($mapping in $environmentVariableMap) {
        $currentValue = $resolved[$mapping.Name]
        $needsValue = $false

        if ($mapping.Name -eq 'UseManagedIdentity') {
            $needsValue = -not $currentValue
        }
        else {
            $needsValue = [string]::IsNullOrWhiteSpace([string]$currentValue)
        }

        if (-not $needsValue) {
            continue
        }

        $match = Get-EnvironmentVariableValue -Names $mapping.Aliases -VariablePrefix $Prefix
        if (-not $match) {
            continue
        }

        $usedEnvironmentVariables = $true
        if (-not $mapping.IsSecret) {
            $usedNonSecretEnvironmentVariables = $true
        }

        switch ($mapping.Name) {
            'ClientSecret' {
                $resolved.ClientSecret = ConvertTo-NullableSecureString -Value $match.Value
            }
            'CertificatePassword' {
                $resolved.CertificatePassword = ConvertTo-NullableSecureString -Value $match.Value
            }
            'UseManagedIdentity' {
                $resolved.UseManagedIdentity = ConvertTo-BooleanValue -Value $match.Value
            }
            default {
                $resolved[$mapping.Name] = $match.Value
            }
        }
    }

    if ($usedEnvironmentVariables -and $usedNonSecretEnvironmentVariables) {
        Write-Warning 'Non-secret configuration read from environment variables. Consider migrating to a centralized configuration file for improved auditability and environment management.'
    }

    if ($resolved.UseManagedIdentity -and $resolved.AuthenticationType -and $resolved.AuthenticationType -ne 'ManagedIdentity') {
        throw [System.Management.Automation.ParameterBindingException]::new(
            'UseManagedIdentity cannot be combined with an AuthenticationType other than ManagedIdentity.'
        )
    }

    if (-not $resolved.AuthenticationType -and $resolved.UseManagedIdentity) {
        $resolved.AuthenticationType = 'ManagedIdentity'
    }

    return $resolved
}

try {
    $resolvedSettings = Resolve-ConnectionSettings
    $endpoints = Get-EnvironmentEndpoints -Environment $resolvedSettings.Environment
    $armResource = $endpoints.Arm.TrimEnd('/')
    $baseUri = $endpoints.Bap.TrimEnd('/')
    $normalizedAuthContext = ConvertTo-Hashtable -InputObject $AuthContext

    $resolvedAuthContext = Resolve-AuthContext `
        -AuthContext $normalizedAuthContext `
        -AuthenticationType $resolvedSettings.AuthenticationType `
        -TenantId $resolvedSettings.TenantId `
        -ClientId $resolvedSettings.ClientId `
        -ClientSecret $resolvedSettings.ClientSecret `
        -CertificatePath $resolvedSettings.CertificatePath `
        -FederatedToken $resolvedSettings.FederatedToken `
        -UseManagedIdentity:([bool]$resolvedSettings.UseManagedIdentity) `
        -Resource $armResource

    if (-not $resolvedAuthContext -or -not $resolvedAuthContext.Token) {
        throw 'Authentication completed without returning an access token.'
    }

    if ($normalizedAuthContext -and $normalizedAuthContext.Method -eq 'ClientCredentials') {
        Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'
    }

    $jwtClaims = Get-JwtClaims -Token $resolvedAuthContext.Token
    $resolvedAuthenticationType = if ($resolvedAuthContext.Method) {
        $resolvedAuthContext.Method
    }
    elseif ($resolvedSettings.AuthenticationType) {
        $resolvedSettings.AuthenticationType
    }
    elseif ($resolvedSettings.UseManagedIdentity) {
        'ManagedIdentity'
    }
    else {
        $null
    }

    return @{
        Token = $resolvedAuthContext.Token
        ExpiresOn = ConvertTo-ExpiryDate -Value $resolvedAuthContext.ExpiresOn -JwtClaims $jwtClaims
        TenantId = if ($resolvedSettings.TenantId) { $resolvedSettings.TenantId } elseif ($resolvedAuthContext.TenantId) { $resolvedAuthContext.TenantId } elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'tid') { [string]$jwtClaims.tid } else { $null }
        ClientId = if ($resolvedSettings.ClientId) { $resolvedSettings.ClientId } elseif ($resolvedAuthContext.ClientId) { $resolvedAuthContext.ClientId } elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'appid') { [string]$jwtClaims.appid } elseif ($jwtClaims -and $jwtClaims.PSObject.Properties.Name -contains 'azp') { [string]$jwtClaims.azp } else { $null }
        Environment = $resolvedSettings.Environment
        BaseUri = $baseUri
        AuthenticationType = $resolvedAuthenticationType
    }
}
catch {
    $message = 'Failed to connect to the Power Platform BAP API. {0}' -f $_.Exception.Message
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

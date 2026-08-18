#Requires -Version 7.2
<#
.SYNOPSIS
Connects to the Dataverse Web API.

.DESCRIPTION
Resolves authentication using the project's normalized authentication parameters,
optionally uses the Global Discovery Service to translate an environment URL to an
API URL, and returns a Dataverse connection context that can be passed to
Invoke-DataverseRequest.ps1.

.PARAMETER EnvironmentUrl
The Dataverse environment URL. Examples include https://org.crm.dynamics.com,
https://org.api.crm.dynamics.com, or a full Web API URL such as
https://org.api.crm.dynamics.com/api/data/v9.2.

.PARAMETER Environment
The Azure cloud environment used for authority host and Global Discovery Service
resolution. Defaults to AzureCloud.

.PARAMETER AuthenticationType
The authentication method to use: ManagedIdentity, Federated, Certificate, or
ClientCredentials.

.PARAMETER UseManagedIdentity
Alias for -AuthenticationType ManagedIdentity.

.OUTPUTS
System.Collections.Specialized.OrderedDictionary

.EXAMPLE
./Connect-DataverseApi.ps1 -AuthenticationType ManagedIdentity -EnvironmentUrl https://contoso.crm.dynamics.com

.EXAMPLE
./Connect-DataverseApi.ps1 -AuthenticationType Federated -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -FederatedToken $oidcToken -Environment AzureUSGovernment -EnvironmentUrl https://contoso.crm9.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentUrl,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

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
    [string]$CertificateThumbprint,

    [Parameter()]
    [string]$CertificatePath,

    [Parameter()]
    [securestring]$CertificatePassword,

    [Parameter()]
    [string]$FederatedToken,

    [Parameter()]
    [switch]$UseManagedIdentity,

    [Parameter()]
    [string]$Prefix,

    [Parameter()]
    [string]$Profile,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force

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
        EnvironmentUrl = 'environmentUrl'
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
        EnvironmentUrl = @('DATAVERSE_ENVIRONMENT_URL')
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

function ConvertTo-PlainText {
    [CmdletBinding()]
    param([Parameter()][securestring]$Value)

    if (-not $Value) {
        return $null
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function ConvertTo-Base64Url {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return ([Convert]::ToBase64String($Bytes).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

function ConvertFrom-UnixTime {
    [CmdletBinding()]
    param([Parameter()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    if ($Value -is [datetime]) {
        return [datetime]$Value
    }

    try {
        $seconds = [int64]$Value
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime
    }
    catch {
        return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    }
}

function Get-JwtClaims {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) {
        return @{}
    }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        default { }
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    $claims = ConvertFrom-Json -InputObject $json -AsHashtable
    if ($null -eq $claims) {
        return @{}
    }

    return $claims
}

function Get-AuthorityHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cloud)

    switch ($Cloud) {
        'AzureCloud' { return 'https://login.microsoftonline.com' }
        'AzureUSGovernment' { return 'https://login.microsoftonline.us' }
        'AzureChinaCloud' { return 'https://login.chinacloudapi.cn' }
        default { throw "Unsupported cloud environment '$Cloud'." }
    }
}

function Get-NormalizedEnvironmentRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    $candidate = $Url.Trim()
    if (-not $candidate.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = "https://$candidate"
    }

    $uri = [Uri]$candidate
    return "$($uri.Scheme)://$($uri.Host)"
}

function Get-DataverseBaseUri {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    $trimmed = $Url.TrimEnd('/')
    if ($trimmed -match '/api/data/v\d+\.\d+$') {
        return $trimmed
    }

    return "$trimmed/api/data/v9.2"
}

function Get-CertificateFromParameters {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Thumbprint,
        [Parameter()][string]$Path,
        [Parameter()][securestring]$Password
    )

    if ($Thumbprint -and $Path) {
        throw [System.Management.Automation.ParameterBindingException]::new('Specify either CertificateThumbprint or CertificatePath, but not both.')
    }

    if (-not $Thumbprint -and -not $Path) {
        throw 'CertificateThumbprint or CertificatePath is required for Certificate authentication.'
    }

    if ($Path) {
        if (-not (Test-Path -Path $Path)) {
            throw "CertificatePath '$Path' was not found."
        }

        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        $plainTextPassword = ConvertTo-PlainText -Value $Password
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Path, $plainTextPassword, $flags)
    }

    $normalizedThumbprint = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    $locations = @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')
    foreach ($location in $locations) {
        if (-not (Test-Path -Path $location)) {
            continue
        }

        $certificate = Get-ChildItem -Path $location | Where-Object { $_.Thumbprint -eq $normalizedThumbprint } | Select-Object -First 1
        if ($certificate) {
            return $certificate
        }
    }

    throw "Certificate with thumbprint '$Thumbprint' was not found in Cert:\CurrentUser\My or Cert:\LocalMachine\My."
}

function New-ClientAssertion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$ClientApplicationId,
        [Parameter(Mandatory)][string]$Audience
    )

    $privateKey = $Certificate.PrivateKey
    if (-not $privateKey) {
        throw 'The selected certificate does not contain an accessible RSA private key.'
    }

    $thumbprintBytes = for ($index = 0; $index -lt $Certificate.Thumbprint.Length; $index += 2) {
        [Convert]::ToByte($Certificate.Thumbprint.Substring($index, 2), 16)
    }

    $now = [DateTimeOffset]::UtcNow
    $header = @{
        alg = 'RS256'
        typ = 'JWT'
        x5t = ConvertTo-Base64Url -Bytes ([byte[]]$thumbprintBytes)
    }
    $payload = @{
        aud = $Audience
        iss = $ClientApplicationId
        sub = $ClientApplicationId
        jti = [guid]::NewGuid().Guid
        nbf = [int64]$now.ToUnixTimeSeconds()
        exp = [int64]$now.AddMinutes(10).ToUnixTimeSeconds()
    }

    $headerJson = ConvertTo-Json -InputObject $header -Compress
    $payloadJson = ConvertTo-Json -InputObject $payload -Compress
    $unsignedToken = '{0}.{1}' -f (ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($headerJson))), (ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($payloadJson)))
    $signature = $privateKey.SignData([Text.Encoding]::UTF8.GetBytes($unsignedToken), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    return '{0}.{1}' -f $unsignedToken, (ConvertTo-Base64Url -Bytes $signature)
}

function Get-ManagedIdentityAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter()][string]$ManagedIdentityClientId,
        [Parameter()][string]$ResolvedTenantId
    )

    $encodedResource = [System.Web.HttpUtility]::UrlEncode($Resource)
    $clientIdQuery = if ($ManagedIdentityClientId) { '&client_id={0}' -f [System.Web.HttpUtility]::UrlEncode($ManagedIdentityClientId) } else { '' }

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $uri = '{0}?resource={1}&api-version=2019-08-01{2}' -f $env:IDENTITY_ENDPOINT, $encodedResource, $clientIdQuery
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
            'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
            Metadata = 'true'
        }

        return [ordered]@{
            Token = $response.access_token
            ExpiresOn = ConvertFrom-UnixTime -Value $response.psobject.properties['expires_on']?.Value
            TenantId = $ResolvedTenantId
            ClientId = $ManagedIdentityClientId
        }
    }

    if ($env:IMDS_ENDPOINT -eq 'http://localhost:40342' -or $env:IDENTITY_ENDPOINT -like 'http://localhost:40342/*') {
        $uri = '{0}?resource={1}&api-version=2020-06-01{2}' -f $env:IDENTITY_ENDPOINT, $encodedResource, $clientIdQuery
        try {
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Metadata = 'True' }
        }
        catch {
            $wwwAuthenticateHeader = $_.Exception.Response.Headers['WWW-Authenticate']
            if (-not $wwwAuthenticateHeader -or $wwwAuthenticateHeader -notmatch 'Basic realm=(.+)') {
                throw
            }

            $secretPath = $Matches[1].Trim('"')
            $secret = Get-Content -Raw -Path $secretPath
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
                Metadata = 'True'
                Authorization = "Basic $secret"
            }
        }

        return [ordered]@{
            Token = $response.access_token
            ExpiresOn = ConvertFrom-UnixTime -Value $response.psobject.properties['expires_on']?.Value
            TenantId = $ResolvedTenantId
            ClientId = $ManagedIdentityClientId
        }
    }

    $imdsUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={0}{1}' -f $encodedResource, $clientIdQuery
    $imdsResponse = Invoke-RestMethod -Method Get -TimeoutSec 5 -NoProxy -Headers @{ Metadata = 'true' } -Uri $imdsUri

    return [ordered]@{
        Token = $imdsResponse.access_token
        ExpiresOn = ConvertFrom-UnixTime -Value $imdsResponse.psobject.properties['expires_on']?.Value
        TenantId = $ResolvedTenantId
        ClientId = $ManagedIdentityClientId
    }
}

function Get-OAuthTokenResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cloud,
        [Parameter(Mandatory)][string]$ResolvedTenantId,
        [Parameter(Mandatory)][string]$ResolvedClientId,
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][hashtable]$Body
    )

    $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f (Get-AuthorityHost -Cloud $Cloud), $ResolvedTenantId
    $baseBody = @{
        client_id = $ResolvedClientId
        scope = "$Resource/.default"
        grant_type = 'client_credentials'
    }

    foreach ($key in $Body.Keys) {
        $baseBody[$key] = $Body[$key]
    }

    return Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -Body $baseBody
}

function New-DataverseAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$Cloud,
        [Parameter()][string]$AuthType,
        [Parameter()][string]$ResolvedTenantId,
        [Parameter()][string]$ResolvedClientId,
        [Parameter()][securestring]$ResolvedClientSecret,
        [Parameter()][string]$ResolvedCertificateThumbprint,
        [Parameter()][string]$ResolvedCertificatePath,
        [Parameter()][securestring]$ResolvedCertificatePassword,
        [Parameter()][string]$ResolvedFederatedToken,
        [Parameter()][switch]$UseManagedIdentitySwitch
    )

    $effectiveAuthType = $AuthType
    if (-not $effectiveAuthType -and $UseManagedIdentitySwitch) {
        $effectiveAuthType = 'ManagedIdentity'
    }

    if (-not $effectiveAuthType) {
        $resolved = Resolve-AuthContext -AuthenticationType $effectiveAuthType -TenantId $ResolvedTenantId -ClientId $ResolvedClientId -ClientSecret $ResolvedClientSecret -CertificatePath $ResolvedCertificatePath -FederatedToken $ResolvedFederatedToken -UseManagedIdentity:$UseManagedIdentitySwitch -Resource $Resource
        return [ordered]@{
            Token = $resolved.Token
            ExpiresOn = $resolved.ExpiresOn
            TenantId = $resolved.TenantId
            ClientId = $resolved.ClientId
        }
    }

    switch ($effectiveAuthType) {
        'ManagedIdentity' {
            return Get-ManagedIdentityAuthContext -Resource $Resource -ManagedIdentityClientId $ResolvedClientId -ResolvedTenantId $ResolvedTenantId
        }
        'Federated' {
            if (-not $ResolvedTenantId) { throw 'TenantId is required for Federated authentication.' }
            if (-not $ResolvedClientId) { throw 'ClientId is required for Federated authentication.' }
            if (-not $ResolvedFederatedToken) { throw 'FederatedToken is required for Federated authentication.' }

            $response = Get-OAuthTokenResponse -Cloud $Cloud -ResolvedTenantId $ResolvedTenantId -ResolvedClientId $ResolvedClientId -Resource $Resource -Body @{
                client_assertion = $ResolvedFederatedToken
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $ResolvedTenantId
                ClientId = $ResolvedClientId
            }
        }
        'Certificate' {
            if (-not $ResolvedTenantId) { throw 'TenantId is required for Certificate authentication.' }
            if (-not $ResolvedClientId) { throw 'ClientId is required for Certificate authentication.' }

            $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f (Get-AuthorityHost -Cloud $Cloud), $ResolvedTenantId
            $certificate = Get-CertificateFromParameters -Thumbprint $ResolvedCertificateThumbprint -Path $ResolvedCertificatePath -Password $ResolvedCertificatePassword
            $clientAssertion = New-ClientAssertion -Certificate $certificate -ClientApplicationId $ResolvedClientId -Audience $tokenUri
            $response = Get-OAuthTokenResponse -Cloud $Cloud -ResolvedTenantId $ResolvedTenantId -ResolvedClientId $ResolvedClientId -Resource $Resource -Body @{
                client_assertion = $clientAssertion
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $ResolvedTenantId
                ClientId = $ResolvedClientId
            }
        }
        'ClientCredentials' {
            if (-not $ResolvedTenantId) { throw 'TenantId is required for ClientCredentials authentication.' }
            if (-not $ResolvedClientId) { throw 'ClientId is required for ClientCredentials authentication.' }
            if (-not $ResolvedClientSecret) { throw 'ClientSecret is required for ClientCredentials authentication.' }

            Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'

            $response = Get-OAuthTokenResponse -Cloud $Cloud -ResolvedTenantId $ResolvedTenantId -ResolvedClientId $ResolvedClientId -Resource $Resource -Body @{
                client_secret = ConvertTo-PlainText -Value $ResolvedClientSecret
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $ResolvedTenantId
                ClientId = $ResolvedClientId
            }
        }
        default {
            throw "Unsupported authentication type '$effectiveAuthType'."
        }
    }
}

function Find-DiscoveredEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestedEnvironmentUrl,
        [Parameter(Mandatory)][object[]]$DiscoveredEnvironments
    )

    $requestedRoot = Get-NormalizedEnvironmentRoot -Url $RequestedEnvironmentUrl
    $requestedHost = ([Uri]$requestedRoot).Host
    $requestedKey = $requestedHost.Split('.')[0]

    foreach ($environmentRecord in $DiscoveredEnvironments) {
        $candidateUrls = @()
        if ($environmentRecord.url) { $candidateUrls += [string]$environmentRecord.url }
        if ($environmentRecord.ApiUrl) { $candidateUrls += [string]$environmentRecord.ApiUrl }
        if ($environmentRecord.ApplicationUrl) { $candidateUrls += [string]$environmentRecord.ApplicationUrl }

        foreach ($candidateUrl in $candidateUrls) {
            if (-not $candidateUrl) {
                continue
            }

            $candidateRoot = Get-NormalizedEnvironmentRoot -Url $candidateUrl
            $candidateHost = ([Uri]$candidateRoot).Host
            if ($candidateHost -eq $requestedHost) {
                return $environmentRecord
            }
        }

        if (($environmentRecord.UniqueName -and $environmentRecord.UniqueName -eq $requestedKey) -or ($environmentRecord.UrlName -and $environmentRecord.UrlName -eq $requestedKey)) {
            return $environmentRecord
        }
    }

    return $null
}

try {
    $requestedEnvironmentRoot = Get-NormalizedEnvironmentRoot -Url $EnvironmentUrl
    $resolvedEnvironmentRoot = $requestedEnvironmentRoot

    if ($PSBoundParameters.ContainsKey('Environment')) {
        $getEnvironmentScriptPath = Join-Path $PSScriptRoot 'Get-DataverseEnvironment.ps1'
        if (Test-Path -Path $getEnvironmentScriptPath) {
            try {
                $discoveryParameters = @{
                    Environment = $Environment
                }

                foreach ($parameterName in @('AuthenticationType', 'TenantId', 'ClientId', 'ClientSecret', 'CertificateThumbprint', 'CertificatePath', 'CertificatePassword', 'FederatedToken')) {
                    if ($PSBoundParameters.ContainsKey($parameterName)) {
                        $discoveryParameters[$parameterName] = $PSBoundParameters[$parameterName]
                    }
                }

                if ($UseManagedIdentity) {
                    $discoveryParameters.UseManagedIdentity = $true
                }

                $discoveredEnvironments = & $getEnvironmentScriptPath @discoveryParameters
                $matchingEnvironment = Find-DiscoveredEnvironment -RequestedEnvironmentUrl $requestedEnvironmentRoot -DiscoveredEnvironments @($discoveredEnvironments)
                if ($matchingEnvironment -and $matchingEnvironment.ApiUrl) {
                    $resolvedEnvironmentRoot = Get-NormalizedEnvironmentRoot -Url $matchingEnvironment.ApiUrl
                }
            }
            catch {
                Write-Verbose "Global Discovery lookup skipped because resolution failed: $($_.Exception.Message)"
            }
        }
    }

    $baseUri = Get-DataverseBaseUri -Url $resolvedEnvironmentRoot
    $authContext = New-DataverseAuthContext -Resource $resolvedEnvironmentRoot -Cloud $Environment -AuthType $AuthenticationType -ResolvedTenantId $TenantId -ResolvedClientId $ClientId -ResolvedClientSecret $ClientSecret -ResolvedCertificateThumbprint $CertificateThumbprint -ResolvedCertificatePath $CertificatePath -ResolvedCertificatePassword $CertificatePassword -ResolvedFederatedToken $FederatedToken -UseManagedIdentitySwitch:$UseManagedIdentity

    $claims = Get-JwtClaims -Token $authContext.Token
    if (-not $authContext.ExpiresOn -and $claims.exp) {
        $authContext.ExpiresOn = ConvertFrom-UnixTime -Value $claims.exp
    }
    if (-not $authContext.TenantId -and $claims.tid) {
        $authContext.TenantId = [string]$claims.tid
    }
    if (-not $authContext.ClientId) {
        if ($claims.appid) {
            $authContext.ClientId = [string]$claims.appid
        }
        elseif ($claims.azp) {
            $authContext.ClientId = [string]$claims.azp
        }
    }

    $effectiveAuthType = $AuthenticationType
    if (-not $effectiveAuthType -and $UseManagedIdentity) {
        $effectiveAuthType = 'ManagedIdentity'
    }

    $connectionContext = @{
        Token = $authContext.Token
        ExpiresOn = $authContext.ExpiresOn
        TenantId = $authContext.TenantId
        ClientId = $authContext.ClientId
        EnvironmentUrl = $resolvedEnvironmentRoot
        BaseUri = $baseUri
        Environment = $Environment
        AuthenticationType = $effectiveAuthType
    }

    return $connectionContext
}
catch {
    $message = "Failed to connect to Dataverse environment '$EnvironmentUrl'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

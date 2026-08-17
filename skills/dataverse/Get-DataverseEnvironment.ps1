#Requires -Version 7.2
<#
.SYNOPSIS
Discovers Dataverse environments by using the Global Discovery Service.

.DESCRIPTION
Queries the Dataverse Global Discovery Service for the selected cloud and returns
environment metadata including name, URL, and ID. If an AuthContext is not
provided, the script resolves authentication using the project's normalized
authentication parameters.

.PARAMETER Environment
The Azure cloud environment to query.

.PARAMETER AuthContext
An authentication context with a bearer token valid for the selected Global
Discovery Service endpoint.

.OUTPUTS
PSCustomObject[]

.EXAMPLE
./Get-DataverseEnvironment.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

.EXAMPLE
./Get-DataverseEnvironment.ps1 -Environment AzureUSGovernment -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -FederatedToken $oidcToken -AuthenticationType Federated
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [Parameter()]
    [hashtable]$AuthContext,

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
    [switch]$UseManagedIdentity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force

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

    try {
        $seconds = [int64]$Value
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime
    }
    catch {
        return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    }
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
    foreach ($location in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
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
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = ConvertTo-Base64Url -Bytes ([byte[]]$thumbprintBytes) }
    $payload = @{
        aud = $Audience
        iss = $ClientApplicationId
        sub = $ClientApplicationId
        jti = [guid]::NewGuid().Guid
        nbf = [int64]$now.ToUnixTimeSeconds()
        exp = [int64]$now.AddMinutes(10).ToUnixTimeSeconds()
    }

    $unsigned = '{0}.{1}' -f (ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $header -Compress)))), (ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Compress))))
    $signature = $privateKey.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return '{0}.{1}' -f $unsigned, (ConvertTo-Base64Url -Bytes $signature)
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
    $requestBody = @{
        client_id = $ResolvedClientId
        scope = "$Resource/.default"
        grant_type = 'client_credentials'
    }

    foreach ($key in $Body.Keys) {
        $requestBody[$key] = $Body[$key]
    }

    return Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -Body $requestBody
}

function New-DiscoveryAuthContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Resource)

    if ($AuthContext -and $AuthContext.Token) {
        return $AuthContext
    }

    $effectiveAuthType = $AuthenticationType
    if (-not $effectiveAuthType -and $UseManagedIdentity) {
        $effectiveAuthType = 'ManagedIdentity'
    }

    if (-not $effectiveAuthType) {
        $resolved = Resolve-AuthContext -AuthenticationType $AuthenticationType -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -CertificatePath $CertificatePath -FederatedToken $FederatedToken -UseManagedIdentity:$UseManagedIdentity -Resource $Resource
        return [ordered]@{
            Token = $resolved.Token
            ExpiresOn = $resolved.ExpiresOn
            TenantId = $resolved.TenantId
            ClientId = $resolved.ClientId
        }
    }

    switch ($effectiveAuthType) {
        'ManagedIdentity' {
            return Get-ManagedIdentityAuthContext -Resource $Resource -ManagedIdentityClientId $ClientId -ResolvedTenantId $TenantId
        }
        'Federated' {
            if (-not $TenantId) { throw 'TenantId is required for Federated authentication.' }
            if (-not $ClientId) { throw 'ClientId is required for Federated authentication.' }
            if (-not $FederatedToken) { throw 'FederatedToken is required for Federated authentication.' }

            $response = Get-OAuthTokenResponse -Cloud $Environment -ResolvedTenantId $TenantId -ResolvedClientId $ClientId -Resource $Resource -Body @{
                client_assertion = $FederatedToken
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $TenantId
                ClientId = $ClientId
            }
        }
        'Certificate' {
            if (-not $TenantId) { throw 'TenantId is required for Certificate authentication.' }
            if (-not $ClientId) { throw 'ClientId is required for Certificate authentication.' }

            $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f (Get-AuthorityHost -Cloud $Environment), $TenantId
            $certificate = Get-CertificateFromParameters -Thumbprint $CertificateThumbprint -Path $CertificatePath -Password $CertificatePassword
            $clientAssertion = New-ClientAssertion -Certificate $certificate -ClientApplicationId $ClientId -Audience $tokenUri
            $response = Get-OAuthTokenResponse -Cloud $Environment -ResolvedTenantId $TenantId -ResolvedClientId $ClientId -Resource $Resource -Body @{
                client_assertion = $clientAssertion
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $TenantId
                ClientId = $ClientId
            }
        }
        'ClientCredentials' {
            if (-not $TenantId) { throw 'TenantId is required for ClientCredentials authentication.' }
            if (-not $ClientId) { throw 'ClientId is required for ClientCredentials authentication.' }
            if (-not $ClientSecret) { throw 'ClientSecret is required for ClientCredentials authentication.' }

            Write-Warning 'Client credential authentication is in use. This method relies on a shared secret and is less secure than managed identity, federated credentials, or certificate-based authentication. Migrate to a higher-trust method if the target service supports it.'

            $response = Get-OAuthTokenResponse -Cloud $Environment -ResolvedTenantId $TenantId -ResolvedClientId $ClientId -Resource $Resource -Body @{
                client_secret = ConvertTo-PlainText -Value $ClientSecret
            }

            return [ordered]@{
                Token = $response.access_token
                ExpiresOn = ConvertFrom-UnixTime -Value $(if ($response.psobject.properties['expires_on']?.Value) { $response.psobject.properties['expires_on'].Value } elseif ($response.psobject.properties['expires_in']?.Value) { [DateTimeOffset]::UtcNow.AddSeconds([int]$response.psobject.properties['expires_in'].Value).ToUnixTimeSeconds() } else { $null })
                TenantId = $TenantId
                ClientId = $ClientId
            }
        }
        default {
            throw "Unsupported authentication type '$effectiveAuthType'."
        }
    }
}

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $discoveryRoot = [string]$endpoints.DataverseGds
    $authContextToUse = New-DiscoveryAuthContext -Resource $discoveryRoot
    $headers = [ordered]@{
        Accept = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version' = '4.0'
    }

    $requestUri = '{0}/api/discovery/v2.0/Instances?$select=FriendlyName,ApiUrl,Id,EnvironmentId,UniqueName,Url,UrlName' -f $discoveryRoot.TrimEnd('/')
    $instances = [System.Collections.Generic.List[object]]::new()
    $nextUri = $requestUri

    while ($nextUri) {
        $response = Invoke-SkillRestMethod -Uri $nextUri -AuthContext $authContextToUse -Method 'GET' -AdditionalHeaders $headers
        if ($null -ne $response.value) {
            foreach ($instance in $response.value) {
                [void]$instances.Add([pscustomobject]@{
                    name = $instance.FriendlyName
                    url = $(if ($instance.ApiUrl) { $instance.ApiUrl } else { $instance.Url })
                    id = $instance.Id
                    ApiUrl = $instance.ApiUrl
                    ApplicationUrl = $instance.Url
                    EnvironmentId = $instance.EnvironmentId
                    UniqueName = $instance.UniqueName
                    UrlName = $instance.UrlName
                })
            }
        }

        $nextUri = if ($response -and $response.PSObject.Properties['@odata.nextLink']) { [string]$response.PSObject.Properties['@odata.nextLink'].Value } else { $null }
    }

    return $instances
}
catch {
    $message = "Failed to query the Dataverse Global Discovery Service for '$Environment'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

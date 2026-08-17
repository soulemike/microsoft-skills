#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes a Log Analytics API authentication context.

.DESCRIPTION
    Creates a Log Analytics connection context that resolves the correct token
    audience and request endpoint from Get-EnvironmentEndpoints in Common.psm1.
    The script supports the normalized authentication parameters used across the
    toolkit and returns a consistent hashtable that can be passed to downstream
    Log Analytics skills.

    Supported authentication methods:
    - Managed Identity
    - Federated credentials
    - Certificate-based service principal
    - Client credentials

.PARAMETER AuthenticationType
    Authentication method to use. Valid values are ManagedIdentity,
    Federated, Certificate, and ClientCredentials.

.PARAMETER TenantId
    Entra ID tenant identifier. Required for Federated, Certificate, and
    ClientCredentials authentication.

.PARAMETER ClientId
    Application (client) identifier. Required for Federated, Certificate, and
    ClientCredentials authentication. Optional for ManagedIdentity and used when
    targeting a user-assigned managed identity.

.PARAMETER ClientSecret
    Secure client secret used only for ClientCredentials authentication.

.PARAMETER CertificatePath
    Path to the certificate file used for Certificate authentication.

.PARAMETER FederatedToken
    OIDC token used for Federated authentication.

.PARAMETER UseManagedIdentity
    Alias for -AuthenticationType ManagedIdentity.

.PARAMETER Environment
    Azure cloud environment used to resolve the Log Analytics endpoints. Valid
    values are AzureCloud, AzureUSGovernment, and AzureChinaCloud.

.PARAMETER AuthContext
    Optional pre-resolved authentication context returned from shared auth
    helpers or another Connect-* script.

.PARAMETER Prefix
    Optional environment variable prefix for multi-tenant configuration.

.PARAMETER Profile
    Optional named profile under config.yaml.

.PARAMETER ConfigPath
    Optional path to a configuration file that contains named profiles.

.OUTPUTS
    Hashtable with Token, ExpiresOn, TenantId, ClientId, Environment, BaseUri,
    and AuthenticationType.

.EXAMPLE
    ./skills/loganalytics/Connect-LogAnalyticsApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

.EXAMPLE
    ./skills/loganalytics/Connect-LogAnalyticsApi.ps1 -Profile prod

.EXAMPLE
    ./skills/loganalytics/Connect-LogAnalyticsApi.ps1 -Prefix GOV -UseManagedIdentity -Environment AzureUSGovernment
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

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [Parameter()]
    [hashtable]$AuthContext,

    [Parameter()]
    [string]$Prefix,

    [Parameter()]
    [string]$Profile,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

if ($UseManagedIdentity -and $AuthenticationType -and $AuthenticationType -ne 'ManagedIdentity') {
    throw [System.Management.Automation.ParameterBindingException]::new(
        'UseManagedIdentity cannot be combined with an AuthenticationType other than ManagedIdentity.'
    )
}

if ($Profile) {
    $effectiveConfigPath = if ($ConfigPath) {
        [System.IO.Path]::GetFullPath($ConfigPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'config.yaml'))
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

if ($Prefix) {
    $envVarMap = @{
        TenantId = @('AZURE_TENANT_ID', 'ARM_TENANT_ID', 'TENANT_ID')
        ClientId = @('AZURE_CLIENT_ID', 'ARM_CLIENT_ID', 'CLIENT_ID')
        ClientSecret = @('AZURE_CLIENT_SECRET', 'ARM_CLIENT_SECRET', 'CLIENT_SECRET')
        CertificatePath = @('AZURE_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PATH', 'CERTIFICATE_PATH')
        FederatedToken = @('AZURE_FEDERATED_TOKEN', 'FEDERATED_TOKEN')
        Environment = @('AZURE_ENVIRONMENT', 'AZURE_CLOUD_ENVIRONMENT', 'ENVIRONMENT')
    }

    foreach ($varName in $envVarMap.Keys) {
        $currentValue = Get-Variable -Name $varName -ValueOnly -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace([string]$currentValue)) {
            $match = Get-PrefixedEnvironmentVariable -Names $envVarMap[$varName] -Prefix $Prefix
            if ($match) {
                if ($varName -eq 'ClientSecret') {
                    Set-Variable -Name $varName -Value (ConvertTo-SecureString -String $match.Value -AsPlainText -Force)
                }
                else {
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

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $tokenAudience = $endpoints.LogAnalyticsTokenAudience
    $baseUri = $endpoints.LogAnalytics.TrimEnd('/')

    $resolvedAuthContext = Resolve-AuthContext `
        -AuthContext $AuthContext `
        -AuthenticationType $AuthenticationType `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ClientSecret $ClientSecret `
        -CertificatePath $CertificatePath `
        -FederatedToken $FederatedToken `
        -UseManagedIdentity:$UseManagedIdentity `
        -Resource $tokenAudience

    if (-not $resolvedAuthContext -or -not $resolvedAuthContext.Token) {
        throw 'Authentication completed without returning an access token.'
    }

    $resolvedAuthenticationType = if ($resolvedAuthContext.ContainsKey('Method')) {
        $resolvedAuthContext.Method
    }
    elseif ($AuthenticationType) {
        $AuthenticationType
    }
    elseif ($UseManagedIdentity) {
        'ManagedIdentity'
    }
    else {
        $null
    }

    return @{
        Token = $resolvedAuthContext.Token
        ExpiresOn = if ($resolvedAuthContext.ContainsKey('ExpiresOn')) { $resolvedAuthContext.ExpiresOn } else { $null }
        TenantId = if ($TenantId) { $TenantId } elseif ($resolvedAuthContext.ContainsKey('TenantId')) { $resolvedAuthContext.TenantId } else { $null }
        ClientId = if ($ClientId) { $ClientId } elseif ($resolvedAuthContext.ContainsKey('ClientId')) { $resolvedAuthContext.ClientId } else { $null }
        Environment = $Environment
        BaseUri = $baseUri
        AuthenticationType = $resolvedAuthenticationType
    }
}
catch {
    $message = 'Failed to connect to Log Analytics. {0}' -f $_.Exception.Message
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

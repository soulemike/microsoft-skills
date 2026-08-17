#Requires -Version 7.2
<#
.SYNOPSIS
    Establishes a Microsoft Graph API authentication context.

.DESCRIPTION
    Creates a Microsoft Graph connection context that is aware of the selected
    Azure environment and uses the shared authentication helpers in
    Common.psm1. The script supports the normalized authentication parameters
    defined in agents.md and returns a consistent context object that can be
    passed to Invoke-GraphRequest.

.PARAMETER AuthenticationType
    Authentication method to use. Valid values are ManagedIdentity,
    Federated, Certificate, and ClientCredentials.

.PARAMETER TenantId
    Entra ID tenant identifier. Required for Federated, Certificate, and
    ClientCredentials authentication.

.PARAMETER ClientId
    Application (client) identifier. Required for Federated, Certificate, and
    ClientCredentials authentication.

.PARAMETER ClientSecret
    Secure client secret used only for ClientCredentials authentication.

.PARAMETER CertificatePath
    Path to the certificate file used for Certificate authentication.

.PARAMETER FederatedToken
    OIDC token used for Federated authentication.

.PARAMETER UseManagedIdentity
    Alias for -AuthenticationType ManagedIdentity.

.PARAMETER Environment
    Azure cloud environment used to resolve the Graph endpoint. Valid values
    are AzureCloud, AzureUSGovernment, and AzureChinaCloud.

    .PARAMETER AuthContext
    Optional pre-resolved authentication context returned from shared auth
    helpers or another Connect-* script.

    .PARAMETER Prefix
    Optional environment variable prefix for multi-tenant configuration.
    For example, -Prefix GOV resolves GOV_TENANT_ID, GOV_CLIENT_ID, etc.

    .PARAMETER Profile
    Optional named profile under config.yaml. Explicit parameters override
    profile values when both are supplied.

    .PARAMETER ConfigPath
    Optional path to a configuration file that contains named profiles.
    Defaults to the repository root config.yaml.

    .OUTPUTS
    Hashtable with Token, ExpiresOn, TenantId, ClientId, Environment,
    GraphEndpoint, and BaseUri.

    .EXAMPLE
    ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

    .EXAMPLE
    ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType Federated -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -FederatedToken $env:AZURE_FEDERATED_TOKEN -Environment AzureUSGovernment

    .EXAMPLE
    ./skills/graph/Connect-GraphApi.ps1 -Profile prod

    .EXAMPLE
    ./skills/graph/Connect-GraphApi.ps1 -Prefix GOV -UseManagedIdentity -Environment AzureUSGovernment
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

$commonModulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..') -ChildPath 'Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

if ($UseManagedIdentity -and $AuthenticationType -and $AuthenticationType -ne 'ManagedIdentity') {
    throw [System.Management.Automation.ParameterBindingException]::new(
        'UseManagedIdentity cannot be combined with an AuthenticationType other than ManagedIdentity.'
    )
}

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
    }

    foreach ($varName in $envVarMap.Keys) {
        $currentValue = Get-Variable -Name $varName -ValueOnly -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace([string]$currentValue)) {
            $match = Get-PrefixedEnvironmentVariable -Names $envVarMap[$varName] -Prefix $Prefix
            if ($match) {
                if ($varName -eq 'ClientSecret') {
                    Set-Variable -Name $varName -Value (ConvertTo-SecureString -String $match.Value -AsPlainText -Force)
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

try {
    $endpoints = Get-EnvironmentEndpoints -Environment $Environment
    $graphEndpoint = $endpoints.Graph.TrimEnd('/')
    $baseUri = '{0}/v1.0' -f $graphEndpoint

    $resolvedAuthContext = Resolve-AuthContext `
        -AuthContext $AuthContext `
        -AuthenticationType $AuthenticationType `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ClientSecret $ClientSecret `
        -CertificatePath $CertificatePath `
        -FederatedToken $FederatedToken `
        -UseManagedIdentity:$UseManagedIdentity `
        -Resource $graphEndpoint

    if (-not $resolvedAuthContext -or -not $resolvedAuthContext.Token) {
        throw 'Authentication completed without returning an access token.'
    }

    $resolvedAuthenticationType = if ($resolvedAuthContext.Method) {
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
        Token              = $resolvedAuthContext.Token
        ExpiresOn          = if ($resolvedAuthContext.ContainsKey('ExpiresOn')) { $resolvedAuthContext.ExpiresOn } else { $null }
        TenantId           = if ($TenantId) { $TenantId } elseif ($resolvedAuthContext.ContainsKey('TenantId')) { $resolvedAuthContext.TenantId } else { $null }
        ClientId           = if ($ClientId) { $ClientId } elseif ($resolvedAuthContext.ContainsKey('ClientId')) { $resolvedAuthContext.ClientId } else { $null }
        Environment        = $Environment
        GraphEndpoint      = $graphEndpoint
        BaseUri            = $baseUri
        AuthenticationType = $resolvedAuthenticationType
    }
}
catch {
    $message = 'Failed to connect to Microsoft Graph. {0}' -f $_.Exception.Message
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

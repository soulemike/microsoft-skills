#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies environment readiness for Microsoft Cloud API Skills execution.

.DESCRIPTION
    Checks the local runtime for the minimum PowerShell version, required module
    availability, Azure CLI presence when applicable, network connectivity to
    cloud endpoints, and the ability to resolve an authentication context by
    testing token acquisition against the selected cloud.

.PARAMETER Environment
    The Azure cloud environment to validate. Supported values are AzureCloud,
    AzureUSGovernment, and AzureChinaCloud.

.PARAMETER Detailed
    Emits a more detailed console report in addition to returning the structured
    status object.

.EXAMPLE
    ./prerequisites/Test-Prerequisites.ps1

.EXAMPLE
    ./prerequisites/Test-Prerequisites.ps1 -Environment AzureUSGovernment -Detailed
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [Parameter()]
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

function Convert-ResourceToScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Resource
    )

    return ('{0}/.default' -f $Resource.TrimEnd('/'))
}

function Get-ModuleSpecifications {
    return @(
        [pscustomobject]@{ RequestedName = 'Az.Accounts'; Candidates = @('Az.Accounts'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Az.Resources'; Candidates = @('Az.Resources'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Az.Compute'; Candidates = @('Az.Compute'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Az.Monitor'; Candidates = @('Az.Monitor'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Az.OperationalInsights'; Candidates = @('Az.OperationalInsights'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Az.SecurityInsights'; Candidates = @('Az.SecurityInsights'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Authentication'; Candidates = @('Microsoft.Graph.Authentication'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Users'; Candidates = @('Microsoft.Graph.Users'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Groups'; Candidates = @('Microsoft.Graph.Groups'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Teams'; Candidates = @('Microsoft.Graph.Teams'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.DeviceManagement'; Candidates = @('Microsoft.Graph.DeviceManagement'); Optional = $false }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Beta.DeviceManagement'; Candidates = @('Microsoft.Graph.Beta.DeviceManagement'); Optional = $true }
        [pscustomobject]@{ RequestedName = 'MSAL.PS'; Candidates = @('MSAL.PS'); Optional = $true }
    )
}

function Get-EnvironmentDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
        [string]$Cloud
    )

    $definitions = @{
        AzureCloud = [ordered]@{
            Name = 'AzureCloud'
            Arm = 'https://management.azure.com/'
            Graph = 'https://graph.microsoft.com/'
            DataverseGlobalDiscovery = 'https://globaldisco.crm.dynamics.com/'
            DataverseEnvironmentPattern = 'https://*.crm.dynamics.com/'
            Bap = 'https://api.bap.microsoft.com/'
            LoginAuthority = 'https://login.microsoftonline.com/'
            ConnectivityTargets = @(
                'https://management.azure.com/'
                'https://graph.microsoft.com/'
                'https://globaldisco.crm.dynamics.com/'
                'https://api.bap.microsoft.com/'
                'https://api.loganalytics.azure.com/'
                'https://login.microsoftonline.com/'
            )
            AzureCliCloudName = 'AzureCloud'
        }
        AzureUSGovernment = [ordered]@{
            Name = 'AzureUSGovernment'
            Arm = 'https://management.usgovcloudapi.net/'
            Graph = 'https://graph.microsoft.us/'
            DataverseGlobalDiscovery = 'https://globaldisco.crm9.dynamics.com/'
            DataverseEnvironmentPattern = 'https://*.crm9.dynamics.com/'
            Bap = 'https://api.bap.microsoft.us/'
            LoginAuthority = 'https://login.microsoftonline.us/'
            ConnectivityTargets = @(
                'https://management.usgovcloudapi.net/'
                'https://graph.microsoft.us/'
                'https://globaldisco.crm9.dynamics.com/'
                'https://api.bap.microsoft.us/'
                'https://api.loganalytics.us/'
                'https://login.microsoftonline.us/'
            )
            AzureCliCloudName = 'AzureUSGovernment'
        }
        AzureChinaCloud = [ordered]@{
            Name = 'AzureChinaCloud'
            Arm = 'https://management.chinacloudapi.cn/'
            Graph = 'https://microsoftgraph.chinacloudapi.cn/'
            DataverseGlobalDiscovery = 'https://globaldisco.crm.dynamics.cn/'
            DataverseEnvironmentPattern = 'https://*.crm.dynamics.cn/'
            Bap = 'https://api.bap.microsoft.cn/'
            LoginAuthority = 'https://login.chinacloudapi.cn/'
            ConnectivityTargets = @(
                'https://management.chinacloudapi.cn/'
                'https://microsoftgraph.chinacloudapi.cn/'
                'https://globaldisco.crm.dynamics.cn/'
                'https://api.bap.microsoft.cn/'
                'https://api.loganalytics.azure.cn/'
                'https://login.chinacloudapi.cn/'
            )
            AzureCliCloudName = 'AzureChinaCloud'
        }
    }

    return [pscustomobject]$definitions[$Cloud]
}

function Get-HighestInstalledModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Candidates
    )

    $installed = foreach ($candidate in $Candidates) {
        Get-Module -ListAvailable -Name $candidate |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    return $installed |
        Where-Object { $_ } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-NormalizedEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Get-NormalizedCredentialContext {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        TenantId = Get-NormalizedEnvironmentValue -Names @('AZURE_TENANT_ID', 'ARM_TENANT_ID', 'TENANT_ID')
        ClientId = Get-NormalizedEnvironmentValue -Names @('AZURE_CLIENT_ID', 'ARM_CLIENT_ID', 'CLIENT_ID')
        ClientSecret = Get-NormalizedEnvironmentValue -Names @('AZURE_CLIENT_SECRET', 'ARM_CLIENT_SECRET', 'CLIENT_SECRET')
        CertificatePath = Get-NormalizedEnvironmentValue -Names @('AZURE_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PATH', 'CERTIFICATE_PATH')
        FederatedToken = Get-NormalizedEnvironmentValue -Names @('AZURE_FEDERATED_TOKEN')
    }
}

function New-SafeFailureDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    return '{0} failed ({1}).' -f $Operation, $Exception.GetType().Name
}

function New-CheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Details,

        [Parameter()]
        [bool]$Required = $true,

        [Parameter()]
        [object]$Data
    )

    return [pscustomobject]@{
        Name = $Name
        Status = $Status
        Required = $Required
        Details = $Details
        Data = $Data
    }
}

function Test-NetworkEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [int]$TimeoutSeconds = 5
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
        return [pscustomobject]@{
            Uri = $Uri
            Status = 'Pass'
            StatusCode = [int]$response.StatusCode
            Details = "Endpoint reachable. HTTP $([int]$response.StatusCode)."
        }
    }
    catch {
        return [pscustomobject]@{
            Uri = $Uri
            Status = 'Fail'
            StatusCode = $null
            Details = $_.Exception.Message
        }
    }
}

function Test-ManagedIdentityToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceUri
    )

    $encodedResource = [System.Web.HttpUtility]::UrlEncode($ResourceUri)

    if ($env:IMDS_ENDPOINT -eq 'http://localhost:40342' -or $env:IDENTITY_ENDPOINT -like 'http://localhost:40342/*') {
        try {
            $endpoint = "$($env:IDENTITY_ENDPOINT)?resource=$encodedResource&api-version=2020-06-01"
            Invoke-WebRequest -Method GET -Uri $endpoint -Headers @{ Metadata = 'True' } -UseBasicParsing | Out-Null
        }
        catch {
            $wwwAuth = $_.Exception.Response.Headers['WWW-Authenticate']
            if ($wwwAuth -match 'Basic realm=(.+)') {
                $secretFile = $Matches[1]
                if (Test-Path -LiteralPath $secretFile) {
                    $secret = Get-Content -LiteralPath $secretFile -Raw
                    $response = Invoke-RestMethod -Method GET -Uri $endpoint -Headers @{ Metadata = 'True'; Authorization = "Basic $secret" }
                    if ($response.access_token) {
                        return [pscustomobject]@{ Success = $true; Method = 'ManagedIdentity'; SubMethod = 'AzureArc'; ExpiresOn = $response.expires_on }
                    }
                }
            }
        }
    }

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        try {
            $response = Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=$encodedResource&api-version=2019-08-01" -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' }
            if ($response.access_token) {
                return [pscustomobject]@{ Success = $true; Method = 'ManagedIdentity'; SubMethod = 'AppService'; ExpiresOn = $response.expires_on }
            }
        }
        catch {
        }
    }

    try {
        $response = Invoke-RestMethod -Method GET -TimeoutSec 2 -NoProxy -Headers @{ Metadata = 'true' } -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource"
        if ($response.access_token) {
            return [pscustomobject]@{ Success = $true; Method = 'ManagedIdentity'; SubMethod = 'IMDS'; ExpiresOn = $response.expires_on }
        }
    }
    catch {
    }

    return [pscustomobject]@{ Success = $false; Method = 'ManagedIdentity'; Details = 'No managed identity endpoint returned a token.' }
}

function Test-FederatedToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$EnvironmentDefinition,

        [Parameter(Mandatory)]
        [pscustomobject]$CredentialContext
    )

    if (-not $CredentialContext.TenantId -or -not $CredentialContext.ClientId) {
        return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = 'TenantId and ClientId are required for federated token validation.' }
    }

    $oidcToken = $CredentialContext.FederatedToken

    if (-not $oidcToken -and $env:GITHUB_ACTIONS -eq 'true' -and $env:ACTIONS_ID_TOKEN_REQUEST_URL -and $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
        try {
            $oidcResponse = Invoke-RestMethod -Method GET -Uri "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange" -Headers @{ Authorization = "bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }
            $oidcToken = $oidcResponse.value
        }
        catch {
            return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = New-SafeFailureDetail -Operation 'GitHub Actions OIDC retrieval' -Exception $_.Exception }
        }
    }

    if (-not $oidcToken -and $env:SYSTEM_OIDCREQUESTURI -and $env:SYSTEM_ACCESSTOKEN) {
        try {
            $oidcUri = "$($env:SYSTEM_OIDCREQUESTURI)?api-version=7.1"
            if ($env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID) {
                $oidcUri += "&serviceConnectionId=$($env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID)"
            }

            $oidcResponse = Invoke-RestMethod -Method POST -Uri $oidcUri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)"; 'Content-Type' = 'application/json' }
            $oidcToken = $oidcResponse.oidcToken
        }
        catch {
            return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = New-SafeFailureDetail -Operation 'Azure DevOps OIDC retrieval' -Exception $_.Exception }
        }
    }

    if (-not $oidcToken -and $env:GITLAB_CI -eq 'true' -and $env:AZURE_FEDERATED_TOKEN) {
        $oidcToken = $env:AZURE_FEDERATED_TOKEN
    }

    if (-not $oidcToken) {
        return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = 'No federated token source was detected.' }
    }

    try {
        $tokenResponse = Invoke-RestMethod -Method POST -Uri "$($EnvironmentDefinition.LoginAuthority)$($CredentialContext.TenantId)/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id = $CredentialContext.ClientId
            scope = Convert-ResourceToScope -Resource $EnvironmentDefinition.Arm
            grant_type = 'client_credentials'
            client_assertion = $oidcToken
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        }

        if ($tokenResponse.access_token) {
            return [pscustomobject]@{ Success = $true; Method = 'Federated'; ExpiresOn = (Get-Date).AddSeconds([int]$tokenResponse.expires_in) }
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = New-SafeFailureDetail -Operation 'Federated token exchange' -Exception $_.Exception }
    }

    return [pscustomobject]@{ Success = $false; Method = 'Federated'; Details = 'Federated token exchange did not return an access token.' }
}

function Test-CertificateToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$EnvironmentDefinition,

        [Parameter(Mandatory)]
        [pscustomobject]$CredentialContext
    )

    if (-not $CredentialContext.CertificatePath) {
        return [pscustomobject]@{ Success = $false; Method = 'Certificate'; Details = 'No certificate path was detected.' }
    }

    if (-not $CredentialContext.TenantId -or -not $CredentialContext.ClientId) {
        return [pscustomobject]@{ Success = $false; Method = 'Certificate'; Details = 'TenantId and ClientId are required for certificate validation.' }
    }

    $msalModule = Get-HighestInstalledModule -Candidates @('MSAL.PS')
    if (-not $msalModule) {
        return [pscustomobject]@{ Success = $false; Method = 'Certificate'; Details = 'MSAL.PS is required for read-only certificate validation.' }
    }

    try {
        Import-Module MSAL.PS -ErrorAction Stop | Out-Null
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CredentialContext.CertificatePath)
        $token = Get-MsalToken -ClientId $CredentialContext.ClientId -TenantId $CredentialContext.TenantId -ClientCertificate $certificate -Scopes (Convert-ResourceToScope -Resource $EnvironmentDefinition.Arm)

        if ($token.AccessToken) {
            return [pscustomobject]@{ Success = $true; Method = 'Certificate'; ExpiresOn = $token.ExpiresOn }
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Method = 'Certificate'; Details = New-SafeFailureDetail -Operation 'Certificate token acquisition' -Exception $_.Exception }
    }

    return [pscustomobject]@{ Success = $false; Method = 'Certificate'; Details = 'Certificate token acquisition did not return an access token.' }
}

function Test-ClientSecretToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$EnvironmentDefinition,

        [Parameter(Mandatory)]
        [pscustomobject]$CredentialContext
    )

    if (-not $CredentialContext.ClientSecret) {
        return [pscustomobject]@{ Success = $false; Method = 'ClientCredentials'; Details = 'No client secret was detected.' }
    }

    if (-not $CredentialContext.TenantId -or -not $CredentialContext.ClientId) {
        return [pscustomobject]@{ Success = $false; Method = 'ClientCredentials'; Details = 'TenantId and ClientId are required for client credential validation.' }
    }

    try {
        $tokenResponse = Invoke-RestMethod -Method POST -Uri "$($EnvironmentDefinition.LoginAuthority)$($CredentialContext.TenantId)/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id = $CredentialContext.ClientId
            client_secret = $CredentialContext.ClientSecret
            scope = Convert-ResourceToScope -Resource $EnvironmentDefinition.Arm
            grant_type = 'client_credentials'
        }

        if ($tokenResponse.access_token) {
            return [pscustomobject]@{ Success = $true; Method = 'ClientCredentials'; ExpiresOn = (Get-Date).AddSeconds([int]$tokenResponse.expires_in) }
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Method = 'ClientCredentials'; Details = New-SafeFailureDetail -Operation 'Client credential token acquisition' -Exception $_.Exception }
    }

    return [pscustomobject]@{ Success = $false; Method = 'ClientCredentials'; Details = 'Client credential token acquisition did not return an access token.' }
}

function Test-AuthenticationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$EnvironmentDefinition,

        [Parameter(Mandatory)]
        [bool]$AzCliInstalled
    )

    $methodsTried = [System.Collections.Generic.List[string]]::new()
    $credentialContext = Get-NormalizedCredentialContext
    $authFailures = [System.Collections.Generic.List[string]]::new()

    $managedIdentityResult = Test-ManagedIdentityToken -ResourceUri $EnvironmentDefinition.Arm
    $methodsTried.Add('ManagedIdentity') | Out-Null
    if ($managedIdentityResult.Success) {
        return New-CheckResult -Name 'AuthenticationContext' -Status 'Pass' -Details "Token acquisition succeeded via $($managedIdentityResult.Method) ($($managedIdentityResult.SubMethod))." -Data ([pscustomobject]@{
            Method = $managedIdentityResult.Method
            SubMethod = $managedIdentityResult.SubMethod
            Resource = $EnvironmentDefinition.Arm
            ExpiresOn = $managedIdentityResult.ExpiresOn
            MethodsTried = $methodsTried
            ReadOnly = $true
        })
    }
    $authFailures.Add($managedIdentityResult.Details) | Out-Null

    if ($AzCliInstalled) {
        $methodsTried.Add('Azure CLI existing context') | Out-Null
        try {
            $tokenJson = az account get-access-token --resource $EnvironmentDefinition.Arm --output json 2>$null | ConvertFrom-Json
            if ($tokenJson.accessToken) {
                return New-CheckResult -Name 'AuthenticationContext' -Status 'Pass' -Details 'Token acquisition succeeded via existing Azure CLI context.' -Data ([pscustomobject]@{
                    Method = 'AzureCli'
                    Resource = $EnvironmentDefinition.Arm
                    Tenant = $tokenJson.tenant
                    Subscription = $tokenJson.subscription
                    ExpiresOn = $tokenJson.expiresOn
                    MethodsTried = $methodsTried
                    ReadOnly = $true
                })
            }
            $authFailures.Add('Azure CLI current context did not return an access token.') | Out-Null
        }
        catch {
            $authFailures.Add((New-SafeFailureDetail -Operation 'Azure CLI current context token acquisition' -Exception $_.Exception)) | Out-Null
        }
    }

    $federatedResult = Test-FederatedToken -EnvironmentDefinition $EnvironmentDefinition -CredentialContext $credentialContext
    $methodsTried.Add('Federated') | Out-Null
    if ($federatedResult.Success) {
        return New-CheckResult -Name 'AuthenticationContext' -Status 'Pass' -Details 'Token acquisition succeeded via federated credentials.' -Data ([pscustomobject]@{
            Method = 'Federated'
            Resource = $EnvironmentDefinition.Arm
            ExpiresOn = $federatedResult.ExpiresOn
            MethodsTried = $methodsTried
            ReadOnly = $true
        })
    }
    $authFailures.Add($federatedResult.Details) | Out-Null

    $certificateResult = Test-CertificateToken -EnvironmentDefinition $EnvironmentDefinition -CredentialContext $credentialContext
    $methodsTried.Add('Certificate') | Out-Null
    if ($certificateResult.Success) {
        return New-CheckResult -Name 'AuthenticationContext' -Status 'Pass' -Details 'Token acquisition succeeded via certificate authentication.' -Data ([pscustomobject]@{
            Method = 'Certificate'
            Resource = $EnvironmentDefinition.Arm
            ExpiresOn = $certificateResult.ExpiresOn
            MethodsTried = $methodsTried
            ReadOnly = $true
        })
    }
    $authFailures.Add($certificateResult.Details) | Out-Null

    $clientSecretResult = Test-ClientSecretToken -EnvironmentDefinition $EnvironmentDefinition -CredentialContext $credentialContext
    $methodsTried.Add('ClientCredentials') | Out-Null
    if ($clientSecretResult.Success) {
        return New-CheckResult -Name 'AuthenticationContext' -Status 'Pass' -Details 'Token acquisition succeeded via client credentials.' -Data ([pscustomobject]@{
            Method = 'ClientCredentials'
            Resource = $EnvironmentDefinition.Arm
            ExpiresOn = $clientSecretResult.ExpiresOn
            MethodsTried = $methodsTried
            ReadOnly = $true
        })
    }
    $authFailures.Add($clientSecretResult.Details) | Out-Null

    $failureDetails = ($authFailures | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '

    return New-CheckResult -Name 'AuthenticationContext' -Status 'Fail' -Details $failureDetails.Trim() -Data ([pscustomobject]@{
        Resource = $EnvironmentDefinition.Arm
        MethodsTried = $methodsTried
        SuggestedActions = @(
            'Configure managed identity, federated credentials, certificate authentication, or client credentials as documented in docs/auth-patterns.md and docs/secret-management.md.'
            'If relying on Azure CLI, ensure az login has been completed for the selected cloud.'
            'If relying on certificate authentication for this read-only check, install MSAL.PS or validate using an existing authenticated context.'
        )
    })
}

$environmentDefinition = Get-EnvironmentDefinition -Cloud $Environment
$moduleSpecifications = Get-ModuleSpecifications

$powerShellCheck = if ($PSVersionTable.PSVersion -ge [version]'7.2.0') {
    New-CheckResult -Name 'PowerShellVersion' -Status 'Pass' -Details "Detected PowerShell $($PSVersionTable.PSVersion)." -Data $PSVersionTable.PSVersion.ToString()
}
else {
    New-CheckResult -Name 'PowerShellVersion' -Status 'Fail' -Details "PowerShell 7.2 or newer is required. Detected $($PSVersionTable.PSVersion)." -Data $PSVersionTable.PSVersion.ToString()
}

$moduleChecks = foreach ($moduleSpecification in $moduleSpecifications) {
    $installed = Get-HighestInstalledModule -Candidates $moduleSpecification.Candidates

    $installedName = if ($installed) { $installed.Name } else { $null }
    $installedVersion = if ($installed) { $installed.Version.ToString() } else { $null }
    $installedPath = if ($installed) { $installed.Path } else { $null }

    [pscustomobject]@{
        RequestedName = $moduleSpecification.RequestedName
        Optional = $moduleSpecification.Optional
        Installed = [bool]$installed
        InstalledName = $installedName
        Version = $installedVersion
        Path = $installedPath
    }
}

$missingRequiredModules = $moduleChecks | Where-Object { -not $_.Optional -and -not $_.Installed }
$moduleSummary = if ($missingRequiredModules.Count -eq 0) {
    New-CheckResult -Name 'RequiredModules' -Status 'Pass' -Details "All required modules are installed. Optional MSAL.PS installed: $([bool](($moduleChecks | Where-Object RequestedName -eq 'MSAL.PS').Installed))." -Data $moduleChecks
}
else {
    $missingNames = ($missingRequiredModules | Select-Object -ExpandProperty RequestedName) -join ', '
    New-CheckResult -Name 'RequiredModules' -Status 'Fail' -Details "Missing required module(s): $missingNames" -Data $moduleChecks
}

$azCommand = Get-Command az -ErrorAction SilentlyContinue
$msalInstalled = [bool](($moduleChecks | Where-Object RequestedName -eq 'MSAL.PS').Installed)
$certificateHintPresent = [bool](Get-NormalizedEnvironmentValue -Names @('AZURE_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PATH', 'CERTIFICATE_PATH'))
$azCliApplicable = $certificateHintPresent -and -not $msalInstalled

if ($azCommand) {
    $azVersionRaw = az version --output json 2>$null
    $azVersion = if ($azVersionRaw) {
        try {
            ((ConvertFrom-Json $azVersionRaw).'azure-cli')
        }
        catch {
            'Unknown'
        }
    }
    else {
        'Unknown'
    }

    $cloudName = $null
    try {
        $cloudName = ((az cloud show --output json 2>$null) | ConvertFrom-Json).name
    }
    catch {
        $cloudName = 'Unknown'
    }

    $details = "Azure CLI is installed (version $azVersion). Active cloud: $cloudName."
    if ($cloudName -ne 'Unknown' -and $cloudName -ne $environmentDefinition.AzureCliCloudName) {
        $details += " Expected cloud for this check: $($environmentDefinition.AzureCliCloudName)."
    }

    $azCliCheck = New-CheckResult -Name 'AzureCli' -Status 'Pass' -Details $details -Required $azCliApplicable -Data ([pscustomobject]@{
        Version = $azVersion
        ActiveCloud = $cloudName
        ExpectedCloud = $environmentDefinition.AzureCliCloudName
        Applicable = $azCliApplicable
    })
}
elseif ($azCliApplicable) {
    $azCliCheck = New-CheckResult -Name 'AzureCli' -Status 'Fail' -Details 'Azure CLI is not installed. It is applicable here because certificate authentication is hinted and MSAL.PS is not installed.' -Required $true -Data ([pscustomobject]@{
        Applicable = $true
    })
}
else {
    $azCliCheck = New-CheckResult -Name 'AzureCli' -Status 'Pass' -Details 'Azure CLI is not installed, but it is not required for the currently detectable prerequisite set.' -Required $false -Data ([pscustomobject]@{
        Applicable = $false
    })
}

$endpointChecks = foreach ($target in $environmentDefinition.ConnectivityTargets) {
    Test-NetworkEndpoint -Uri $target
}

$failedEndpoints = $endpointChecks | Where-Object Status -eq 'Fail'
$networkCheck = if ($failedEndpoints.Count -eq 0) {
    New-CheckResult -Name 'NetworkConnectivity' -Status 'Pass' -Details "All $($endpointChecks.Count) endpoint connectivity checks succeeded for $Environment." -Data $endpointChecks
}
else {
    $failedUris = ($failedEndpoints | Select-Object -ExpandProperty Uri) -join ', '
    New-CheckResult -Name 'NetworkConnectivity' -Status 'Fail' -Details "Network connectivity failed for: $failedUris" -Data $endpointChecks
}

$authenticationCheck = Test-AuthenticationContext -EnvironmentDefinition $environmentDefinition -AzCliInstalled ([bool]$azCommand)

$checks = @(
    $powerShellCheck
    $moduleSummary
    $azCliCheck
    $networkCheck
    $authenticationCheck
)

$requiredFailures = $checks | Where-Object { $_.Required -and $_.Status -eq 'Fail' }

$report = [pscustomobject]@{
    Timestamp = Get-Date
    Environment = $Environment
    OverallStatus = if ($requiredFailures.Count -eq 0) { 'Pass' } else { 'Fail' }
    Checks = $checks
}

if ($Detailed) {
    Write-Host "Prerequisite report for $Environment"
    Write-Host "Overall status: $($report.OverallStatus)"
    foreach ($check in $checks) {
        Write-Host "[$($check.Status)] $($check.Name): $($check.Details)"
    }
}

return $report

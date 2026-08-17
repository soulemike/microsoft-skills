#Requires -Version 7.2
<#
.SYNOPSIS
    Installs the PowerShell modules required by the Microsoft Cloud API Skills toolkit.

.DESCRIPTION
    Ensures the required Az and Microsoft.Graph modules are present for the
    skill toolkit, and optionally installs MSAL.PS to support certificate-based
    authentication flows without relying on Azure CLI.

    The script checks for existing module installations before installing.
    Use -Force to update or reinstall existing modules.

.PARAMETER Scope
    Installation scope for Install-Module / Update-Module. Valid values are
    CurrentUser and AllUsers. Defaults to CurrentUser.

.PARAMETER Force
    Reinstall or update modules even when a version is already installed.

.EXAMPLE
    ./prerequisites/Install-RequiredModules.ps1

.EXAMPLE
    ./prerequisites/Install-RequiredModules.ps1 -Scope AllUsers -Force
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:TrustedRepositoryName = 'PSGallery'

function Get-ModuleSpecifications {
    return @(
        [pscustomobject]@{ RequestedName = 'Az.Accounts'; Candidates = @('Az.Accounts'); Category = 'Az'; Optional = $false; Purpose = 'Azure authentication and token acquisition' }
        [pscustomobject]@{ RequestedName = 'Az.Resources'; Candidates = @('Az.Resources'); Category = 'Az'; Optional = $false; Purpose = 'Azure resource management' }
        [pscustomobject]@{ RequestedName = 'Az.Compute'; Candidates = @('Az.Compute'); Category = 'Az'; Optional = $false; Purpose = 'VM and compute operations' }
        [pscustomobject]@{ RequestedName = 'Az.Monitor'; Candidates = @('Az.Monitor'); Category = 'Az'; Optional = $false; Purpose = 'Azure Monitor operations' }
        [pscustomobject]@{ RequestedName = 'Az.OperationalInsights'; Candidates = @('Az.OperationalInsights'); Category = 'Az'; Optional = $false; Purpose = 'Log Analytics and Sentinel data plane operations' }
        [pscustomobject]@{ RequestedName = 'Az.SecurityInsights'; Candidates = @('Az.SecurityInsights'); Category = 'Az'; Optional = $false; Purpose = 'Microsoft Sentinel management plane operations' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Authentication'; Candidates = @('Microsoft.Graph.Authentication'); Category = 'Microsoft.Graph'; Optional = $false; Purpose = 'Graph authentication and session management' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Users'; Candidates = @('Microsoft.Graph.Users'); Category = 'Microsoft.Graph'; Optional = $false; Purpose = 'User operations' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Groups'; Candidates = @('Microsoft.Graph.Groups'); Category = 'Microsoft.Graph'; Optional = $false; Purpose = 'Group operations' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Teams'; Candidates = @('Microsoft.Graph.Teams'); Category = 'Microsoft.Graph'; Optional = $false; Purpose = 'Teams operations' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.DeviceManagement'; Candidates = @('Microsoft.Graph.DeviceManagement'); Category = 'Microsoft.Graph'; Optional = $false; Purpose = 'Intune v1.0 device management operations' }
        [pscustomobject]@{ RequestedName = 'Microsoft.Graph.Beta.DeviceManagement'; Candidates = @('Microsoft.Graph.Beta.DeviceManagement'); Category = 'Microsoft.Graph.Beta'; Optional = $true; Purpose = 'Intune beta device management operations (SDK alternative to raw REST)' }
        [pscustomobject]@{ RequestedName = 'MSAL.PS'; Candidates = @('MSAL.PS'); Category = 'Optional'; Optional = $true; Purpose = 'Certificate authentication without Azure CLI fallback' }
    )
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

function Assert-TrustedRepository {
    [CmdletBinding()]
    param()

    $repository = Get-PSRepository -Name $script:TrustedRepositoryName -ErrorAction SilentlyContinue
    if (-not $repository) {
        throw "Required repository '$($script:TrustedRepositoryName)' is not registered. Register PowerShell Gallery before running this script."
    }

    if ($repository.InstallationPolicy -ne 'Trusted') {
        throw "Repository '$($script:TrustedRepositoryName)' is registered but not trusted. Set its installation policy to Trusted before running this script."
    }

    return $repository
}

function Install-OrUpdateModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Specification,

        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$InstallScope,

        [Parameter(Mandatory)]
        [bool]$Reinstall
    )

    $existingModule = Get-HighestInstalledModule -Candidates $Specification.Candidates
    $action = if ($existingModule) { 'AlreadyInstalled' } else { 'Missing' }
    $operationMessage = $null
    $installError = $null

    if (-not $existingModule -or $Reinstall) {
        $null = Assert-TrustedRepository

        foreach ($candidate in $Specification.Candidates) {
            try {
                Install-Module -Name $candidate -Repository $script:TrustedRepositoryName -Scope $InstallScope -AllowClobber -Force:$Reinstall -ErrorAction Stop
                $action = if ($existingModule -and $Reinstall) { 'Updated' } else { 'Installed' }

                $operationMessage = "Resolved using module '$candidate'."
                $installError = $null
                break
            }
            catch {
                $installError = $_.Exception.Message
            }
        }
    }

    $resolvedModule = Get-HighestInstalledModule -Candidates $Specification.Candidates

    if (-not $resolvedModule) {
        $status = if ($Specification.Optional) { 'OptionalModuleUnavailable' } else { 'Failed' }
        $details = if ($installError) {
            "Unable to install module candidate(s): $installError"
        }
        else {
            'Module is not installed.'
        }
    }
    else {
        $status = 'Installed'
        $details = switch ($action) {
            'AlreadyInstalled' { 'Module already installed. No action required.' }
            'Installed' { 'Module installed successfully.' }
            'Updated' { 'Module updated successfully.' }
            'Reinstalled' { 'Module reinstalled successfully.' }
            default { 'Module resolved successfully.' }
        }

        if ($operationMessage) {
            $details = "$details $operationMessage"
        }
    }

    $installedName = if ($resolvedModule) { $resolvedModule.Name } else { $null }
    $installedVersion = if ($resolvedModule) { $resolvedModule.Version.ToString() } else { $null }
    $installedPath = if ($resolvedModule) { $resolvedModule.Path } else { $null }

    return [pscustomobject]@{
        RequestedName = $Specification.RequestedName
        InstalledName = $installedName
        Category = $Specification.Category
        Optional = $Specification.Optional
        Purpose = $Specification.Purpose
        Status = $status
        Version = $installedVersion
        Path = $installedPath
        Scope = $InstallScope
        Repository = $script:TrustedRepositoryName
        Details = $details
    }
}

$moduleSpecifications = Get-ModuleSpecifications
$results = foreach ($moduleSpecification in $moduleSpecifications) {
    Install-OrUpdateModule -Specification $moduleSpecification -InstallScope $Scope -Reinstall $Force.IsPresent
}

$requiredFailures = $results | Where-Object { -not $_.Optional -and $_.Status -eq 'Failed' }

$summary = [pscustomobject]@{
    Timestamp = Get-Date
    Scope = $Scope
    Repository = $script:TrustedRepositoryName
    Force = $Force.IsPresent
    Success = ($requiredFailures.Count -eq 0)
    InstalledModules = $results
}

return $summary

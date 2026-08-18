#Requires -Version 7.2
<#
.SYNOPSIS
    Imports Microsoft service modules in a conflict-aware order, with optional
    DllPickle preload integration.

.DESCRIPTION
    Loading Az.* and Microsoft.Graph.* modules in the same PowerShell session can
    trigger assembly version conflicts ("Assembly with same name is already loaded").
    This helper mitigates that risk by:

    1. Detecting whether DLLPickle is installed and invoking Import-DPLibrary first.
    2. Falling back to a manual module load-order heuristic if DLLPickle is absent.
    3. Warning when known-incompatible module pairs are loaded together.

    The preload / block classification and load-order reasoning are derived from
    DllPickle (https://github.com/SamErde/DLLPickle) by Sam Erde, used under MIT
    license with gratitude and explicit attribution.

.PARAMETER Modules
    The module names to import. Defaults to the full set used by this toolkit.

.PARAMETER SkipDLLPickle
    Do not attempt to use DLLPickle even if it is installed.

.PARAMETER Force
    Re-import modules even if already loaded.

.EXAMPLE
    ./prerequisites/Import-ConflictSafeModules.ps1

    Imports the default module set with conflict awareness.

.EXAMPLE
    ./prerequisites/Import-ConflictSafeModules.ps1 -Modules @('Az.Accounts','Microsoft.Graph.Authentication') -Verbose

    Imports only the specified modules.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Modules = @(
        'Az.Accounts'
        'Az.Resources'
        'Az.Compute'
        'Az.Monitor'
        'Az.OperationalInsights'
        'Az.SecurityInsights'
        'Microsoft.Graph.Authentication'
        'Microsoft.Graph.Users'
        'Microsoft.Graph.Groups'
        'Microsoft.Graph.Teams'
        'Microsoft.Graph.DeviceManagement'
        'MSAL.PS'
    ),

    [Parameter()]
    [switch]$SkipDLLPickle,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Attribution notice
# ---------------------------------------------------------------------------
Write-Verbose 'DLL conflict mitigation approach derived from DllPickle (https://github.com/SamErde/DLLPickle) by Sam Erde. MIT License.'

# ---------------------------------------------------------------------------
# Known conflict pairs: modules that should not be loaded in the same session
# without DllPickle or explicit load-order management.
# ---------------------------------------------------------------------------
$script:KnownConflictPairs = @(
    @('Az.Accounts', 'Microsoft.Graph.Authentication'),
    @('Az.Accounts', 'MSAL.PS'),
    @('Microsoft.Graph.Authentication', 'MSAL.PS')
)

function Test-KnownConflictPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$RequestedModules
    )

    $loaded = @{}
    foreach ($mod in $RequestedModules) {
        $loaded[$mod] = $true
    }

    foreach ($pair in $script:KnownConflictPairs) {
        $a = $pair[0]
        $b = $pair[1]
        if ($loaded[$a] -and $loaded[$b]) {
            Write-Warning "Known DLL conflict pair detected: $a and $b. Ensure DllPickle is loaded first (see docs/dll-conflict-mitigation.md)."
        }
    }
}

function Get-ModuleLoadPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )

    # Load order heuristic inspired by DllPickle's "first one wins" strategy.
    # Modules with lower numbers are loaded first.
    # MSAL.PS has the smallest surface and is loaded first so its Microsoft.Identity.Client
    # version wins if DllPickle is not present. Graph is next. Az is last because
    # Az.Accounts 5.x+ self-isolates Azure SDK assemblies in a private ALC,
    # but it still shares the default ALC for MSAL/IdentityModel.
    switch -Wildcard ($ModuleName) {
        'MSAL.PS'                         { return 1 }
        'Microsoft.Graph.Authentication'  { return 10 }
        'Microsoft.Graph.*'               { return 20 }
        'Az.Accounts'                     { return 30 }
        'Az.*'                            { return 40 }
        default                           { return 50 }
    }
}

function Import-ModuleSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [switch]$ForceImport
    )

    $alreadyLoaded = Get-Module -Name $Name
    if ($alreadyLoaded -and -not $ForceImport) {
        Write-Verbose "Module '$Name' is already loaded. Skipping."
        return [pscustomobject]@{ Name = $Name; Status = 'AlreadyLoaded'; Version = $alreadyLoaded.Version }
    }

    try {
        $importParams = @{ Name = $Name; ErrorAction = 'Stop' }
        if ($ForceImport) {
            $importParams['Force'] = $true
        }
        Import-Module @importParams
        $loaded = Get-Module -Name $Name
        Write-Verbose "Module '$Name' loaded successfully (version $($loaded.Version))."
        return [pscustomobject]@{ Name = $Name; Status = 'Loaded'; Version = $loaded.Version }
    }
    catch {
        Write-Warning "Failed to import module '$Name': $_"
        return [pscustomobject]@{ Name = $Name; Status = 'Failed'; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Step 1: Warn on known conflict pairs
# ---------------------------------------------------------------------------
Test-KnownConflictPair -RequestedModules $Modules

# ---------------------------------------------------------------------------
# Step 2: Attempt DllPickle preload if available and not skipped
# ---------------------------------------------------------------------------
$dllPicklePreloaded = $false
if (-not $SkipDLLPickle) {
    $dllPickleAvailable = Get-Module -ListAvailable -Name DLLPickle | Select-Object -First 1
    if ($dllPickleAvailable) {
        Write-Verbose 'DllPickle is available. Preloading compatible identity assemblies...'
        try {
            Import-Module DLLPickle -ErrorAction Stop
            Import-DPLibrary -ErrorAction Stop
            $dllPicklePreloaded = $true
            Write-Host 'DllPickle: Identity assemblies preloaded successfully.'
        }
        catch {
            Write-Warning "DllPickle preload failed: $_. Proceeding with manual load-order fallback."
        }
    }
    else {
        Write-Verbose 'DllPickle is not installed. Skipping preload. Consider: Install-Module DLLPickle -Scope CurrentUser'
    }
}

# ---------------------------------------------------------------------------
# Step 3: Sort modules by load priority and import
# ---------------------------------------------------------------------------
$sortedModules = $Modules | Sort-Object { Get-ModuleLoadPriority -ModuleName $_ }

$results = foreach ($mod in $sortedModules) {
    Import-ModuleSafely -Name $mod -ForceImport:$Force
}

# ---------------------------------------------------------------------------
# Step 4: Summary
# ---------------------------------------------------------------------------
$loadedCount = ($results | Where-Object Status -in @('Loaded','AlreadyLoaded')).Count
$failedCount = ($results | Where-Object Status -eq 'Failed').Count

$summary = [pscustomobject]@{
    Timestamp = Get-Date
    DLLPicklePreloaded = $dllPicklePreloaded
    ModulesRequested = $Modules
    ModulesLoaded = $loadedCount
    ModulesFailed = $failedCount
    Results = $results
}

if ($failedCount -gt 0) {
    Write-Warning "$failedCount module(s) failed to import. Review the Results property for details."
}

return $summary

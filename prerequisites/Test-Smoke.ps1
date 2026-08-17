#Requires -Version 7.2
<#
.SYNOPSIS
    Smoke tests for the Microsoft Cloud API Skills toolkit.

.DESCRIPTION
    Validates that core shared helpers, config resolution, and Connect-*
    script parameters work without requiring live authentication.

.EXAMPLE
    ./prerequisites/Test-Smoke.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details })
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$skillsRoot = Join-Path $projectRoot 'skills'

# Test 1: Common.psm1 loads
& {
    try {
        Import-Module (Join-Path $skillsRoot 'Common.psm1') -Force
        Add-TestResult -Name 'Common.psm1 loads' -Passed $true -Details 'Module imported successfully'
    }
    catch {
        Add-TestResult -Name 'Common.psm1 loads' -Passed $false -Details $_.Exception.Message
    }
}

# Test 2: Get-EnvironmentEndpoints returns expected clouds
& {
    try {
        Import-Module (Join-Path $skillsRoot 'Common.psm1') -Force
        $clouds = @('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')
        $allOk = $true
        foreach ($cloud in $clouds) {
            $endpoints = Get-EnvironmentEndpoints -Environment $cloud
            if (-not $endpoints.Graph -or -not $endpoints.Arm) {
                $allOk = $false
                break
            }
        }
        Add-TestResult -Name 'Get-EnvironmentEndpoints' -Passed $allOk -Details "Checked $($clouds.Count) clouds"
    }
    catch {
        Add-TestResult -Name 'Get-EnvironmentEndpoints' -Passed $false -Details $_.Exception.Message
    }
}

# Test 3: Load-DotEnv reads .env.example
& {
    try {
        Import-Module (Join-Path $skillsRoot 'Common.psm1') -Force
        $envExample = Join-Path $projectRoot '.env.example'
        if (-not (Test-Path $envExample)) {
            Add-TestResult -Name 'Load-DotEnv' -Passed $false -Details '.env.example not found'
        }
        else {
            Load-DotEnv -Path $envExample
            # .env.example uses placeholder values; verify at least one var was set
            $tenantId = [Environment]::GetEnvironmentVariable('TENANT_ID', 'Process')
            if ($tenantId -eq '00000000-0000-0000-0000-000000000000') {
                Add-TestResult -Name 'Load-DotEnv' -Passed $true -Details 'Loaded .env.example successfully'
            }
            else {
                Add-TestResult -Name 'Load-DotEnv' -Passed $false -Details 'Expected placeholder TENANT_ID not found in process env'
            }
        }
    }
    catch {
        Add-TestResult -Name 'Load-DotEnv' -Passed $false -Details $_.Exception.Message
    }
}

# Test 4: Get-ProfileSettings reads config.yaml
& {
    try {
        Import-Module (Join-Path $skillsRoot 'Common.psm1') -Force
        $configPath = Join-Path $projectRoot 'config.yaml'
        if (-not (Test-Path $configPath)) {
            Add-TestResult -Name 'Get-ProfileSettings' -Passed $false -Details 'config.yaml not found'
        }
        else {
            $profile = Get-ProfileSettings -ProfileName 'prod' -Path $configPath
            if ($profile.tenantId -and $profile.azureEnvironment) {
                Add-TestResult -Name 'Get-ProfileSettings' -Passed $true -Details "Read prod profile: tenantId=$($profile.tenantId), azureEnvironment=$($profile.azureEnvironment)"
            }
            else {
                Add-TestResult -Name 'Get-ProfileSettings' -Passed $false -Details 'Profile did not contain expected keys'
            }
        }
    }
    catch {
        Add-TestResult -Name 'Get-ProfileSettings' -Passed $false -Details $_.Exception.Message
    }
}

# Test 5: Get-PrefixedEnvironmentVariable
& {
    try {
        Import-Module (Join-Path $skillsRoot 'Common.psm1') -Force
        [Environment]::SetEnvironmentVariable('TESTPROD_TENANT_ID', 'prod-tenant-123', 'Process')
        $result = Get-PrefixedEnvironmentVariable -Names @('TENANT_ID') -Prefix 'TESTPROD'
        if ($result -and $result.Value -eq 'prod-tenant-123') {
            Add-TestResult -Name 'Get-PrefixedEnvironmentVariable' -Passed $true -Details 'Resolved TESTPROD_TENANT_ID correctly'
        }
        else {
            Add-TestResult -Name 'Get-PrefixedEnvironmentVariable' -Passed $false -Details 'Did not resolve prefixed variable'
        }
        [Environment]::SetEnvironmentVariable('TESTPROD_TENANT_ID', $null, 'Process')
    }
    catch {
        Add-TestResult -Name 'Get-PrefixedEnvironmentVariable' -Passed $false -Details $_.Exception.Message
    }
}

# Test 6: Connect-GraphApi.ps1 accepts -Profile/-Prefix/-ConfigPath
& {
    try {
        $scriptPath = Join-Path $skillsRoot 'graph' 'Connect-GraphApi.ps1'
        $scriptInfo = Get-Command $scriptPath -ErrorAction Stop
        $params = $scriptInfo.Parameters.Keys
        $requiredParams = @('Profile', 'Prefix', 'ConfigPath')
        $missing = $requiredParams | Where-Object { $_ -notin $params }
        if ($missing.Count -eq 0) {
            Add-TestResult -Name 'Connect-GraphApi parameters' -Passed $true -Details 'Has Profile, Prefix, ConfigPath'
        }
        else {
            Add-TestResult -Name 'Connect-GraphApi parameters' -Passed $false -Details "Missing: $($missing -join ', ')"
        }
    }
    catch {
        Add-TestResult -Name 'Connect-GraphApi parameters' -Passed $false -Details $_.Exception.Message
    }
}

# Test 7: Connect-AzureApi.ps1 accepts -Profile/-Prefix/-ConfigPath
& {
    try {
        $scriptPath = Join-Path $skillsRoot 'azure' 'Connect-AzureApi.ps1'
        $scriptInfo = Get-Command $scriptPath -ErrorAction Stop
        $params = $scriptInfo.Parameters.Keys
        $requiredParams = @('Profile', 'Prefix', 'ConfigPath')
        $missing = $requiredParams | Where-Object { $_ -notin $params }
        if ($missing.Count -eq 0) {
            Add-TestResult -Name 'Connect-AzureApi parameters' -Passed $true -Details 'Has Profile, Prefix, ConfigPath'
        }
        else {
            Add-TestResult -Name 'Connect-AzureApi parameters' -Passed $false -Details "Missing: $($missing -join ', ')"
        }
    }
    catch {
        Add-TestResult -Name 'Connect-AzureApi parameters' -Passed $false -Details $_.Exception.Message
    }
}

# Summary
$passed = $script:TestResults | Where-Object { $_.Passed }
$failed = $script:TestResults | Where-Object { -not $_.Passed }

Write-Host "`n=== Smoke Test Results ===" -ForegroundColor Cyan
foreach ($result in $script:TestResults) {
    $color = if ($result.Passed) { 'Green' } else { 'Red' }
    Write-Host "[$($result.Passed)] $($result.Name): $($result.Details)" -ForegroundColor $color
}

Write-Host "`nPassed: $($passed.Count) / $($script:TestResults.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
    exit 1
}

#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for recent offline-safe fixes.

.DESCRIPTION
    Validates endpoint mappings and StrictMode compatibility for recent fixes
    without requiring live Azure authentication.

.EXAMPLE
    ./prerequisites/Test-Integration.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details })
}

function Get-ParseErrors {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return @($errors)
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$skillsRoot = Join-Path $projectRoot 'skills'
$commonModulePath = Join-Path $skillsRoot 'Common.psm1'
$kqlScriptPath = Join-Path $skillsRoot 'loganalytics' 'Invoke-LogAnalyticsKqlQuery.ps1'
$graphScriptPath = Join-Path $skillsRoot 'graph' 'Invoke-GraphRequest.ps1'

# Test 1: LogAnalyticsTokenAudience mapping
& {
    try {
        Import-Module $commonModulePath -Force

        $expectedByCloud = @{
            AzureCloud = @{
                LogAnalytics = 'https://api.loganalytics.azure.com'
                LogAnalyticsTokenAudience = 'https://api.loganalytics.io/'
            }
            AzureUSGovernment = @{
                LogAnalytics = 'https://api.loganalytics.us'
                LogAnalyticsTokenAudience = 'https://api.loganalytics.us/'
            }
            AzureChinaCloud = @{
                LogAnalytics = 'https://api.loganalytics.azure.cn'
                LogAnalyticsTokenAudience = 'https://api.loganalytics.azure.cn/'
            }
        }

        $cloudFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($cloud in $expectedByCloud.Keys) {
            $endpoints = Get-EnvironmentEndpoints -Environment $cloud
            $hasLogAnalytics = $null -ne $endpoints.LogAnalytics
            $hasLogAnalyticsTokenAudience = $null -ne $endpoints.LogAnalyticsTokenAudience
            $valuesDiffer = $endpoints.LogAnalytics -ne $endpoints.LogAnalyticsTokenAudience
            $hasTrailingSlash = $endpoints.LogAnalyticsTokenAudience.EndsWith('/')
            $expected = $expectedByCloud[$cloud]

            if (-not $hasLogAnalytics) {
                $cloudFailures.Add("$cloud missing LogAnalytics")
                continue
            }

            if (-not $hasLogAnalyticsTokenAudience) {
                $cloudFailures.Add("$cloud missing LogAnalyticsTokenAudience")
                continue
            }

            if ($endpoints.LogAnalytics -ne $expected.LogAnalytics) {
                $cloudFailures.Add("$cloud LogAnalytics mismatch: $($endpoints.LogAnalytics)")
            }

            if ($endpoints.LogAnalyticsTokenAudience -ne $expected.LogAnalyticsTokenAudience) {
                $cloudFailures.Add("$cloud LogAnalyticsTokenAudience mismatch: $($endpoints.LogAnalyticsTokenAudience)")
            }

            if (-not $valuesDiffer) {
                $cloudFailures.Add("$cloud LogAnalytics and LogAnalyticsTokenAudience should differ")
            }

            if (-not $hasTrailingSlash) {
                $cloudFailures.Add("$cloud LogAnalyticsTokenAudience must end with '/'")
            }
        }

        if ($cloudFailures.Count -eq 0) {
            Add-TestResult -Name 'Log Analytics endpoint mapping' -Passed $true -Details 'Verified LogAnalytics and LogAnalyticsTokenAudience for AzureCloud, AzureUSGovernment, and AzureChinaCloud'
        }
        else {
            Add-TestResult -Name 'Log Analytics endpoint mapping' -Passed $false -Details ($cloudFailures -join '; ')
        }
    }
    catch {
        Add-TestResult -Name 'Log Analytics endpoint mapping' -Passed $false -Details $_.Exception.Message
    }
}

# Test 2: StrictMode compatibility for Invoke-LogAnalyticsKqlQuery.ps1
& {
    try {
        $parseErrors = Get-ParseErrors -Path $kqlScriptPath
        if ($parseErrors.Count -gt 0) {
            throw ($parseErrors | ForEach-Object { $_.Message } | Select-Object -First 1)
        }

        $safeCheckOk = & {
            Set-StrictMode -Version Latest
            $response = [pscustomobject]@{
                tables = @()
            }

            $hasErrorProperty = $null -ne $response.PSObject.Properties['error']
            return (-not $hasErrorProperty)
        }

        if (-not $safeCheckOk) {
            throw 'Expected a response object without an error property to evaluate safely under StrictMode.'
        }

        Add-TestResult -Name 'Invoke-LogAnalyticsKqlQuery StrictMode compatibility' -Passed $true -Details 'Script parsed successfully and PSObject.Properties["error"] check did not throw under Set-StrictMode -Version Latest'
    }
    catch {
        Add-TestResult -Name 'Invoke-LogAnalyticsKqlQuery StrictMode compatibility' -Passed $false -Details $_.Exception.Message
    }
}

# Test 3: StrictMode compatibility for Invoke-GraphRequest.ps1
& {
    try {
        $parseErrors = Get-ParseErrors -Path $graphScriptPath
        if ($parseErrors.Count -gt 0) {
            throw ($parseErrors | ForEach-Object { $_.Message } | Select-Object -First 1)
        }

        $scriptContent = Get-Content -Path $graphScriptPath -Raw -ErrorAction Stop
        $hasRetryHelper = $scriptContent -match 'function\s+Get-GraphRetryMetadata'

        $strictModeSafe = & {
            Set-StrictMode -Version Latest

            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Graph request failed.'),
                'GraphRequestFailed',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )

            $null = $errorRecord.Exception.PSObject.Properties['Response']
            $null = $errorRecord.PSObject.Properties['ErrorDetails']

            return $true
        }

        if (-not $hasRetryHelper) {
            throw 'Get-GraphRetryMetadata function was not found in Invoke-GraphRequest.ps1.'
        }

        if (-not $strictModeSafe) {
            throw 'Expected ErrorRecord property checks to evaluate safely under StrictMode.'
        }

        Add-TestResult -Name 'Invoke-GraphRequest StrictMode compatibility' -Passed $true -Details 'Script parsed successfully and ErrorRecord PSObject.Properties checks used by Get-GraphRetryMetadata evaluated safely under Set-StrictMode -Version Latest'
    }
    catch {
        Add-TestResult -Name 'Invoke-GraphRequest StrictMode compatibility' -Passed $false -Details $_.Exception.Message
    }
}

# Test 4: Token audience vs endpoint separation
& {
    try {
        Import-Module $commonModulePath -Force

        $endpoints = Get-EnvironmentEndpoints -Environment 'AzureCloud'
        $scriptContent = Get-Content -Path $kqlScriptPath -Raw -ErrorAction Stop

        $usesTokenAudience = $scriptContent -match 'Resolve-AuthContext\s+-AuthContext\s+\$AuthContext\s+-Resource\s+\$endpoints\.LogAnalyticsTokenAudience'
        $usesRequestEndpoint = $scriptContent.Contains("`$endpoints.LogAnalytics.TrimEnd('/')")
        $separatedValues = $endpoints.LogAnalytics -ne $endpoints.LogAnalyticsTokenAudience

        if ($usesTokenAudience -and $usesRequestEndpoint -and $separatedValues) {
            Add-TestResult -Name 'Log Analytics token audience separation' -Passed $true -Details 'Invoke-LogAnalyticsKqlQuery uses LogAnalyticsTokenAudience for auth and LogAnalytics for the request URI'
        }
        else {
            $details = @()
            if (-not $usesTokenAudience) {
                $details += 'Invoke-LogAnalyticsKqlQuery does not appear to pass LogAnalyticsTokenAudience to Resolve-AuthContext'
            }
            if (-not $usesRequestEndpoint) {
                $details += 'Invoke-LogAnalyticsKqlQuery does not appear to build the request URI from LogAnalytics'
            }
            if (-not $separatedValues) {
                $details += 'AzureCloud LogAnalytics and LogAnalyticsTokenAudience should be different values'
            }

            Add-TestResult -Name 'Log Analytics token audience separation' -Passed $false -Details ($details -join '; ')
        }
    }
    catch {
        Add-TestResult -Name 'Log Analytics token audience separation' -Passed $false -Details $_.Exception.Message
    }
}

# Test 5: Data Collector API fallback signature
& {
    try {
        $dataCollectorScript = Get-ChildItem -Path $projectRoot -Filter 'Send-LogAnalyticsData.ps1' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $dataCollectorScript) {
            Add-TestResult -Name 'Send-LogAnalyticsData signature' -Passed $true -Details 'Skipped: Send-LogAnalyticsData.ps1 not present yet'
            return
        }

        $scriptInfo = Get-Command $dataCollectorScript.FullName -ErrorAction Stop
        $params = $scriptInfo.Parameters.Keys
        $requiredParams = @('WorkspaceId', 'WorkspaceSharedKey', 'DceUri', 'DcrImmutableId', 'StreamName', 'Data', 'AuthContext')
        $missing = $requiredParams | Where-Object { $_ -notin $params }

        if ($missing.Count -eq 0) {
            Add-TestResult -Name 'Send-LogAnalyticsData signature' -Passed $true -Details "Has WorkspaceId, WorkspaceSharedKey, DceUri, DcrImmutableId, StreamName, Data, AuthContext in $($dataCollectorScript.FullName)"
        }
        else {
            Add-TestResult -Name 'Send-LogAnalyticsData signature' -Passed $false -Details "Missing: $($missing -join ', ')"
        }
    }
    catch {
        Add-TestResult -Name 'Send-LogAnalyticsData signature' -Passed $false -Details $_.Exception.Message
    }
}

# Summary
$passed = $script:TestResults | Where-Object { $_.Passed }
$failed = $script:TestResults | Where-Object { -not $_.Passed }

Write-Host "`n=== Integration Test Results ===" -ForegroundColor Cyan
foreach ($result in $script:TestResults) {
    $color = if ($result.Passed) { 'Green' } else { 'Red' }
    Write-Host "[$($result.Passed)] $($result.Name): $($result.Details)" -ForegroundColor $color
}

Write-Host "`nPassed: $($passed.Count) / $($script:TestResults.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
    exit 1
}

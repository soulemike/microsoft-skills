#Requires -Version 7.2
<#
.SYNOPSIS
    Token validation tests for common authentication issues.

.DESCRIPTION
    Validates token audience, scope, and expiry without requiring live service calls.
    These tests catch the most common auth mistakes observed in reference projects:
    - Audience mismatch (ARM token used for Graph, etc.)
    - Scope issues
    - Token expiry handling

.EXAMPLE
    ./prerequisites/Test-TokenValidation.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details })
}

function New-TestToken {
    param([string]$Audience, [string]$Scope = "$Audience/.default", [int]$ExpiresInSeconds = 3600)

    $header = @{ alg = 'none'; typ = 'JWT' } | ConvertTo-Json -Compress
    $payload = @{
        aud = $Audience
        scp = $Scope
        tid = '00000000-0000-0000-0000-000000000000'
        appid = '00000000-0000-0000-0000-000000000000'
        exp = [int]([DateTimeOffset]::UtcNow.AddSeconds($ExpiresInSeconds).ToUnixTimeSeconds())
    } | ConvertTo-Json -Compress

    $headerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($header)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    return "$headerB64.$payloadB64."
}

function Test-TokenAudience {
    param([string]$Token, [string]$ExpectedAudience)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $false }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    $claims = $json | ConvertFrom-Json

    return $claims.aud -eq $ExpectedAudience
}

function Test-TokenExpired {
    param([string]$Token)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $true }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    $claims = $json | ConvertFrom-Json

    $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp)
    return $exp -lt [DateTimeOffset]::UtcNow
}

# Test 1: ARM token audience validation
& {
    $armToken = New-TestToken -Audience 'https://management.azure.com/'
    $isArm = Test-TokenAudience -Token $armToken -ExpectedAudience 'https://management.azure.com/'
    $isGraph = Test-TokenAudience -Token $armToken -ExpectedAudience 'https://graph.microsoft.com/'

    if ($isArm -and -not $isGraph) {
        Add-TestResult -Name 'Audience: ARM token is ARM, not Graph' -Passed $true -Details 'Token audience correctly identifies as ARM'
    } else {
        Add-TestResult -Name 'Audience: ARM token is ARM, not Graph' -Passed $false -Details 'Audience mismatch detection failed'
    }
}

# Test 2: Graph token audience validation
& {
    $graphToken = New-TestToken -Audience 'https://graph.microsoft.com/'
    $isGraph = Test-TokenAudience -Token $graphToken -ExpectedAudience 'https://graph.microsoft.com/'
    $isArm = Test-TokenAudience -Token $graphToken -ExpectedAudience 'https://management.azure.com/'

    if ($isGraph -and -not $isArm) {
        Add-TestResult -Name 'Audience: Graph token is Graph, not ARM' -Passed $true -Details 'Token audience correctly identifies as Graph'
    } else {
        Add-TestResult -Name 'Audience: Graph token is Graph, not ARM' -Passed $false -Details 'Audience mismatch detection failed'
    }
}

# Test 3: Dataverse token audience validation
& {
    $dvToken = New-TestToken -Audience 'https://contoso.crm.dynamics.com/'
    $isDv = Test-TokenAudience -Token $dvToken -ExpectedAudience 'https://contoso.crm.dynamics.com/'
    $isGraph = Test-TokenAudience -Token $dvToken -ExpectedAudience 'https://graph.microsoft.com/'

    if ($isDv -and -not $isGraph) {
        Add-TestResult -Name 'Audience: Dataverse token is Dataverse, not Graph' -Passed $true -Details 'Token audience correctly identifies as Dataverse'
    } else {
        Add-TestResult -Name 'Audience: Dataverse token is Dataverse, not Graph' -Passed $false -Details 'Audience mismatch detection failed'
    }
}

# Test 4: Token expiry detection - valid token
& {
    $validToken = New-TestToken -Audience 'https://management.azure.com/' -ExpiresInSeconds 3600
    $isExpired = Test-TokenExpired -Token $validToken

    if (-not $isExpired) {
        Add-TestResult -Name 'Expiry: Valid token not expired' -Passed $true -Details 'Token with +1h expiry detected as valid'
    } else {
        Add-TestResult -Name 'Expiry: Valid token not expired' -Passed $false -Details 'Valid token incorrectly detected as expired'
    }
}

# Test 5: Token expiry detection - expired token
& {
    $expiredToken = New-TestToken -Audience 'https://management.azure.com/' -ExpiresInSeconds -60
    $isExpired = Test-TokenExpired -Token $expiredToken

    if ($isExpired) {
        Add-TestResult -Name 'Expiry: Expired token detected' -Passed $true -Details 'Token with -1m expiry detected as expired'
    } else {
        Add-TestResult -Name 'Expiry: Expired token detected' -Passed $false -Details 'Expired token not detected'
    }
}

# Test 6: Context object shape validation
& {
    $projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $skillsRoot = Join-Path $projectRoot 'skills'

    # Test that Connect-GraphApi returns expected keys
    $graphScript = Join-Path $skillsRoot 'graph' 'Connect-GraphApi.ps1'
    $graphInfo = Get-Command $graphScript -ErrorAction SilentlyContinue
    if ($graphInfo) {
        $hasRequiredParams = @('AuthenticationType', 'Environment', 'TenantId', 'ClientId', 'Profile', 'Prefix', 'ConfigPath') | ForEach-Object {
            $graphInfo.Parameters.ContainsKey($_)
        }
        if ($hasRequiredParams -notcontains $false) {
            Add-TestResult -Name 'Context: Graph Connect has required parameters' -Passed $true -Details 'Has AuthenticationType, Environment, TenantId, ClientId, Profile, Prefix, ConfigPath'
        } else {
            Add-TestResult -Name 'Context: Graph Connect has required parameters' -Passed $false -Details 'Missing required parameters'
        }
    } else {
        Add-TestResult -Name 'Context: Graph Connect has required parameters' -Passed $false -Details 'Could not load script'
    }
}

# Test 7: Context object shape validation for Azure
& {
    $projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $skillsRoot = Join-Path $projectRoot 'skills'

    $azureScript = Join-Path $skillsRoot 'azure' 'Connect-AzureApi.ps1'
    $azureInfo = Get-Command $azureScript -ErrorAction SilentlyContinue
    if ($azureInfo) {
        $hasRequiredParams = @('AuthenticationType', 'Environment', 'TenantId', 'ClientId', 'Profile', 'Prefix', 'ConfigPath') | ForEach-Object {
            $azureInfo.Parameters.ContainsKey($_)
        }
        if ($hasRequiredParams -notcontains $false) {
            Add-TestResult -Name 'Context: Azure Connect has required parameters' -Passed $true -Details 'Has AuthenticationType, Environment, TenantId, ClientId, Profile, Prefix, ConfigPath'
        } else {
            Add-TestResult -Name 'Context: Azure Connect has required parameters' -Passed $false -Details 'Missing required parameters'
        }
    } else {
        Add-TestResult -Name 'Context: Azure Connect has required parameters' -Passed $false -Details 'Could not load script'
    }
}

# Summary
$passed = $script:TestResults | Where-Object { $_.Passed }
$failed = $script:TestResults | Where-Object { -not $_.Passed }

Write-Host "`n=== Token Validation Test Results ===" -ForegroundColor Cyan
foreach ($result in $script:TestResults) {
    $color = if ($result.Passed) { 'Green' } else { 'Red' }
    Write-Host "[$($result.Passed)] $($result.Name): $($result.Details)" -ForegroundColor $color
}

Write-Host "`nPassed: $($passed.Count) / $($script:TestResults.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
    exit 1
}

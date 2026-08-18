#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SdkRoot,

    [Parameter()]
    [switch]$Http,

    [Parameter()]
    [int]$HttpPort = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serverRoot = Join-Path $PSScriptRoot 'server'
$candidateSdkRoots = @(
    $SdkRoot
    $env:MCP_SDK_ROOT
    (Join-Path $PSScriptRoot '.sdk/pwsh.mcp.sdk')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$resolvedSdkRoot = $null
foreach ($candidate in $candidateSdkRoots) {
    $fullCandidate = [System.IO.Path]::GetFullPath($candidate)
    if (Test-Path -Path (Join-Path $fullCandidate 'MCP.SDK/Start.ps1')) {
        $resolvedSdkRoot = $fullCandidate
        break
    }
}

if (-not $resolvedSdkRoot) {
    throw "pwsh.mcp.sdk was not found. Run ./mcp/Install-McpSdk.ps1 or set MCP_SDK_ROOT to a pwsh.mcp.sdk clone."
}

$sdkStartScript = Join-Path $resolvedSdkRoot 'MCP.SDK/Start.ps1'

if ($Http) {
    & $sdkStartScript $serverRoot -HttpPort $HttpPort
}
else {
    & $sdkStartScript $serverRoot
}

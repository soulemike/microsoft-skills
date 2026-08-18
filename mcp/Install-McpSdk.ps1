#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter()]
    [string]$DestinationPath = (Join-Path $PSScriptRoot '.sdk/pwsh.mcp.sdk'),

    [Parameter()]
    [string]$RepositoryZipUrl = 'https://github.com/KevinMarquette/pwsh.mcp.sdk/archive/refs/heads/main.zip',

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedDestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)

if ((Test-Path -Path $resolvedDestinationPath) -and -not $Force) {
    return [pscustomobject]@{
        Installed = $true
        Path = $resolvedDestinationPath
        Changed = $false
    }
}

if (Test-Path -Path $resolvedDestinationPath) {
    Remove-Item -Path $resolvedDestinationPath -Recurse -Force
}

$parentDirectory = Split-Path -Path $resolvedDestinationPath -Parent
New-Item -Path $parentDirectory -ItemType Directory -Force | Out-Null

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporaryRoot 'pwsh-mcp-sdk.zip'
$extractPath = Join-Path $temporaryRoot 'expanded'

try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    Invoke-WebRequest -Uri $RepositoryZipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $sdkRoot = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
    if (-not $sdkRoot) {
        throw 'Unable to locate the extracted pwsh.mcp.sdk content.'
    }

    Move-Item -Path $sdkRoot.FullName -Destination $resolvedDestinationPath

    return [pscustomobject]@{
        Installed = $true
        Path = $resolvedDestinationPath
        Changed = $true
    }
}
finally {
    if (Test-Path -Path $temporaryRoot) {
        Remove-Item -Path $temporaryRoot -Recurse -Force
    }
}

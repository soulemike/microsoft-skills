#Requires -Version 7.2

Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$script:ContextStore = @{}
$script:ContextCounter = 0

function Get-MicrosoftCloudApiSkillsRepositoryRoot {
    return $script:RepositoryRoot
}

function ConvertTo-McpPlainValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or
        $InputObject -is [int] -or
        $InputObject -is [long] -or
        $InputObject -is [double] -or
        $InputObject -is [decimal] -or
        $InputObject -is [bool] -or
        $InputObject -is [datetime] -or
        $InputObject -is [datetimeoffset] -or
        $InputObject -is [guid]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = ConvertTo-McpPlainValue -InputObject $InputObject[$key]
        }

        return $table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = foreach ($item in $InputObject) {
            ConvertTo-McpPlainValue -InputObject $item
        }

        return @($items)
    }

    $properties = $InputObject.PSObject.Properties
    if ($properties.Count -gt 0) {
        $table = @{}
        foreach ($property in $properties) {
            $table[$property.Name] = ConvertTo-McpPlainValue -InputObject $property.Value
        }

        return $table
    }

    return $InputObject
}

function ConvertTo-McpSecureString {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $secureString = [System.Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) {
        $secureString.AppendChar($character)
    }

    $secureString.MakeReadOnly()
    return $secureString
}

function Save-McpContextRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContextType,

        [Parameter(Mandatory)]
        [hashtable]$Payload
    )

    $script:ContextCounter++
    $contextId = '{0}-{1}' -f $ContextType, $script:ContextCounter

    $record = [ordered]@{
        ContextId = $contextId
        ContextType = $ContextType
    }

    foreach ($key in $Payload.Keys) {
        $record[$key] = ConvertTo-McpPlainValue -InputObject $Payload[$key]
    }

    $script:ContextStore[$contextId] = $record
    return $record
}

function Get-McpContextRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContextId
    )

    if (-not $script:ContextStore.ContainsKey($ContextId)) {
        throw "No stored MCP auth context was found for ContextId '$ContextId'."
    }

    return $script:ContextStore[$ContextId]
}

function Resolve-McpContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ContextId,

        [Parameter()]
        [AllowNull()]
        [object]$AuthContext,

        [Parameter(Mandatory)]
        [ValidateSet('AuthContext', 'Graph', 'Azure', 'LogAnalytics', 'SentinelArm', 'Intune')]
        [string]$Purpose
    )

    $candidate = if (-not [string]::IsNullOrWhiteSpace($ContextId)) {
        Get-McpContextRecord -ContextId $ContextId
    }
    else {
        ConvertTo-McpPlainValue -InputObject $AuthContext
    }

    if ($null -eq $candidate) {
        throw 'Either ContextId or AuthContext is required.'
    }

    if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('ContextId') -and -not $candidate.Contains('Token')) {
        $candidate = Get-McpContextRecord -ContextId ([string]$candidate.ContextId)
    }

    if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('Token')) {
        return $candidate
    }

    if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('AuthContext')) {
        return ConvertTo-McpPlainValue -InputObject $candidate.AuthContext
    }

    if ($candidate -is [System.Collections.IDictionary] -and $Purpose -eq 'SentinelArm' -and $candidate.Contains('SentinelArmContext')) {
        return ConvertTo-McpPlainValue -InputObject $candidate.SentinelArmContext
    }

    if ($candidate -is [System.Collections.IDictionary] -and $Purpose -eq 'LogAnalytics' -and $candidate.Contains('LogAnalyticsContext')) {
        return ConvertTo-McpPlainValue -InputObject $candidate.LogAnalyticsContext
    }

    throw "The supplied context does not contain a usable auth payload for purpose '$Purpose'."
}

function Invoke-MicrosoftCloudApiSkillScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter()]
        [hashtable]$Parameters = @{}
    )

    $scriptPath = Join-Path $script:RepositoryRoot $RelativePath
    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
        throw "Script not found: $scriptPath"
    }

    $savedWarningPreference = $WarningPreference
    $savedInformationPreference = $InformationPreference

    try {
        $WarningPreference = 'Continue'
        $InformationPreference = 'Continue'

        $output = & $scriptPath @Parameters 3>&1 6>&1
    }
    finally {
        $WarningPreference = $savedWarningPreference
        $InformationPreference = $savedInformationPreference
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $messages = [System.Collections.Generic.List[string]]::new()
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($output)) {
        if ($item -is [System.Management.Automation.WarningRecord]) {
            $warnings.Add($item.Message)
            continue
        }

        if ($item -is [System.Management.Automation.InformationRecord]) {
            $messages.Add([string]$item.MessageData)
            continue
        }

        $results.Add($item)
    }

    $result = if ($results.Count -eq 0) {
        $null
    }
    elseif ($results.Count -eq 1) {
        $results[0]
    }
    else {
        @($results)
    }

    return [ordered]@{
        Result = ConvertTo-McpPlainValue -InputObject $result
        Warnings = @($warnings)
        Messages = @($messages)
    }
}

function Format-McpToolResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Data,

        [Parameter()]
        [string[]]$Warnings = @(),

        [Parameter()]
        [string[]]$Messages = @()
    )

    return [ordered]@{
        Data = ConvertTo-McpPlainValue -InputObject $Data
        Warnings = @($Warnings)
        Messages = @($Messages)
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-McpPlainValue',
    'ConvertTo-McpSecureString',
    'Get-MicrosoftCloudApiSkillsRepositoryRoot',
    'Invoke-MicrosoftCloudApiSkillScript',
    'Save-McpContextRecord',
    'Format-McpToolResult',
    'Resolve-McpContext'
)

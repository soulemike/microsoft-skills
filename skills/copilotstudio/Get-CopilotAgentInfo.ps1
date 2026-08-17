#Requires -Version 7.2
<#
.SYNOPSIS
Gets Copilot Studio agent metadata from Dataverse.

.DESCRIPTION
Queries the Dataverse bot entity set that backs Copilot Studio agents. The script
uses the Dataverse environment URL from the supplied Context object as the base
URI and supports OData $select and $filter query options for list operations.

When AgentId is provided, the script retrieves a single bot record. Otherwise,
it lists bot records and follows Dataverse @odata.nextLink pagination until all
pages are returned.

.PARAMETER AgentId
Optional Copilot Studio agent identifier. When supplied, only the specified bot
record is returned.

.PARAMETER Select
Optional array of properties to request through $select, for example
@('botid', 'name', 'statecode', 'statuscode').

.PARAMETER Filter
Optional OData $filter expression for list operations.

.PARAMETER Context
Dataverse connection context returned by Connect-DataverseApi.ps1 or a
compatible hashtable that contains Token, TenantId, ClientId, Environment, and
BaseUri.

.PARAMETER AuthenticationType
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER TenantId
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER ClientId
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER ClientSecret
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER CertificatePath
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER CertificatePassword
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER FederatedToken
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER UseManagedIdentity
Normalized authentication parameter included for cross-skill consistency.

.PARAMETER Environment
Normalized cloud environment value included for cross-skill consistency.

.OUTPUTS
System.Object

.EXAMPLE
./skills/copilotstudio/Get-CopilotAgentInfo.ps1 -Context $context

.EXAMPLE
./skills/copilotstudio/Get-CopilotAgentInfo.ps1 -Context $context -Select @('botid', 'name', 'statuscode') -Filter "statecode eq 0"

.EXAMPLE
./skills/copilotstudio/Get-CopilotAgentInfo.ps1 -Context $context -AgentId '00000000-0000-0000-0000-000000000000'
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AgentId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Select,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Filter,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$Context,

    [Parameter()]
    [ValidateSet('ManagedIdentity', 'Federated', 'Certificate', 'ClientCredentials')]
    [string]$AuthenticationType,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [securestring]$ClientSecret,

    [Parameter()]
    [string]$CertificatePath,

    [Parameter()]
    [securestring]$CertificatePassword,

    [Parameter()]
    [string]$FederatedToken,

    [Parameter()]
    [switch]$UseManagedIdentity,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $PSScriptRoot/../Common.psm1

$script:HasTenantId = $PSBoundParameters.ContainsKey('TenantId')
$script:HasClientId = $PSBoundParameters.ContainsKey('ClientId')
$script:HasEnvironment = $PSBoundParameters.ContainsKey('Environment')

function Copy-ContextHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Source
    )

    $copy = @{}
    foreach ($key in $Source.Keys) {
        $copy[$key] = $Source[$key]
    }

    return $copy
}

function Get-ValidatedCopilotContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InputContext
    )

    $requiredFields = @('Token', 'BaseUri')
    foreach ($field in $requiredFields) {
        if (-not $InputContext.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$InputContext[$field])) {
            throw "Context must contain a non-empty '$field' value."
        }
    }

    $resolvedContext = Copy-ContextHashtable -Source $InputContext

    if (-not $resolvedContext.ContainsKey('TenantId') -and $script:HasTenantId) {
        $resolvedContext.TenantId = $TenantId
    }

    if (-not $resolvedContext.ContainsKey('ClientId') -and $script:HasClientId) {
        $resolvedContext.ClientId = $ClientId
    }

    if (-not $resolvedContext.ContainsKey('Environment') -and $script:HasEnvironment) {
        $resolvedContext.Environment = $Environment
    }

    return $resolvedContext
}

function New-DataverseHeaders {
    [CmdletBinding()]
    param()

    return [ordered]@{
        Accept = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version' = '4.0'
        'If-None-Match' = 'null'
    }
}

function ConvertTo-SelectQueryString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Properties
    )

    $distinctProperties = $Properties | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    if (-not $distinctProperties) {
        return $null
    }

    return [System.Uri]::EscapeDataString(($distinctProperties -join ','))
}

function Get-AgentEntitySetUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedContext,

        [Parameter()]
        [string]$RecordId,

        [Parameter()]
        [string]$SelectQuery,

        [Parameter()]
        [string]$FilterQuery
    )

    $baseUri = $ResolvedContext.BaseUri.TrimEnd('/')
    $uriBuilder = [System.Text.StringBuilder]::new()
    [void]$uriBuilder.Append("$baseUri/bots")

    if ($RecordId) {
        [void]$uriBuilder.Append("($RecordId)")
    }

    $queryParts = [System.Collections.Generic.List[string]]::new()
    if ($SelectQuery) {
        $queryParts.Add("`$select=$SelectQuery")
    }

    if ($FilterQuery -and -not $RecordId) {
        $queryParts.Add("`$filter=$([System.Uri]::EscapeDataString($FilterQuery))")
    }

    if ($queryParts.Count -gt 0) {
        [void]$uriBuilder.Append('?')
        [void]$uriBuilder.Append(($queryParts -join '&'))
    }

    return $uriBuilder.ToString()
}

function ConvertFrom-DataverseCollectionResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response -is [System.Array]) {
        return $Response
    }

    if ($Response -and $Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }

    return @($Response)
}

try {
    $resolvedContext = Get-ValidatedCopilotContext -InputContext $Context
    $selectQuery = if ($PSBoundParameters.ContainsKey('Select')) {
        ConvertTo-SelectQueryString -Properties $Select
    }
    else {
        $null
    }

    $headers = New-DataverseHeaders
    $requestUri = Get-AgentEntitySetUri -ResolvedContext $resolvedContext -RecordId $AgentId -SelectQuery $selectQuery -FilterQuery $Filter

    if ($PSBoundParameters.ContainsKey('AgentId')) {
        return Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'GET' -AdditionalHeaders $headers
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $requestUri

    while ($nextUri) {
        $response = Invoke-SkillRestMethod -Uri $nextUri -AuthContext $resolvedContext -Method 'GET' -AdditionalHeaders $headers
        foreach ($item in (ConvertFrom-DataverseCollectionResponse -Response $response)) {
            [void]$results.Add($item)
        }

        $nextUri = $response.'@odata.nextLink'
    }

    return $results
}
catch {
    $message = if ($PSBoundParameters.ContainsKey('AgentId')) {
        "Failed to retrieve Copilot Studio agent '$AgentId'. $($_.Exception.Message)"
    }
    else {
        "Failed to list Copilot Studio agents from Dataverse. $($_.Exception.Message)"
    }

    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

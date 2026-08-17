#Requires -Version 7.2
<#
.SYNOPSIS
Manages Copilot Studio knowledge sources in Dataverse.

.DESCRIPTION
Performs CRUD-style operations against the Dataverse entity set used for Copilot
Studio knowledge sources. The exact knowledge source entity set and agent
relationship field can vary by environment and solution version, so this script
defaults to the generic entity set name 'knowledgesources' and allows overrides
through parameters.

List operations can optionally scope results to an agent by applying an OData
filter against AgentFilterField. Create and Update operations accept a
KnowledgeSourceData hashtable so callers can supply the exact columns and
relationship bindings required by their environment.

.PARAMETER Operation
The knowledge source operation to perform: List, Get, Create, Update, or Delete.

.PARAMETER AgentId
Optional Copilot Studio agent identifier. For List operations, AgentId is used
with AgentFilterField to scope results. For Create and Update operations, callers
can also include any required relationship bindings inside KnowledgeSourceData.

.PARAMETER KnowledgeSourceId
Knowledge source identifier for Get, Update, and Delete operations.

.PARAMETER KnowledgeSourceData
Hashtable payload used for Create and Update operations. Because knowledge source
schemas differ across environments, callers should provide the exact Dataverse
columns needed by their environment.

.PARAMETER KnowledgeEntitySetName
Dataverse entity set name for knowledge sources. Defaults to 'knowledgesources',
but some environments may expose a different entity set.

.PARAMETER AgentFilterField
Dataverse field used to scope knowledge sources to an agent during List
operations. Defaults to '_botid_value', which is common for Dataverse lookups,
but may need to be overridden in customized environments.

.PARAMETER Filter
Optional additional OData $filter expression for List operations.

.PARAMETER Select
Optional array of properties to request through $select.

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
./skills/copilotstudio/Manage-CopilotKnowledge.ps1 -Context $context -Operation List -AgentId $agentId

.EXAMPLE
./skills/copilotstudio/Manage-CopilotKnowledge.ps1 -Context $context -Operation Create -KnowledgeSourceData @{ name = 'Docs'; 'bot@odata.bind' = "/bots($agentId)" }

.EXAMPLE
./skills/copilotstudio/Manage-CopilotKnowledge.ps1 -Context $context -Operation Update -KnowledgeSourceId $knowledgeId -KnowledgeSourceData @{ name = 'Updated Docs' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('List', 'Get', 'Create', 'Update', 'Delete')]
    [string]$Operation,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AgentId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KnowledgeSourceId,

    [Parameter()]
    [hashtable]$KnowledgeSourceData,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KnowledgeEntitySetName = 'knowledgesources',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AgentFilterField = '_botid_value',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Filter,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Select,

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
$script:HasAgentId = $PSBoundParameters.ContainsKey('AgentId')
$script:HasFilter = $PSBoundParameters.ContainsKey('Filter')
$script:HasKnowledgeSourceId = $PSBoundParameters.ContainsKey('KnowledgeSourceId')

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

function Get-CombinedKnowledgeFilter {
    [CmdletBinding()]
    param()

    $filterParts = [System.Collections.Generic.List[string]]::new()

    if ($script:HasAgentId) {
        $filterParts.Add("$AgentFilterField eq $AgentId")
    }

    if ($script:HasFilter) {
        $filterParts.Add("($Filter)")
    }

    if ($filterParts.Count -eq 0) {
        return $null
    }

    return ($filterParts -join ' and ')
}

function Get-KnowledgeEntityUri {
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
    [void]$uriBuilder.Append("$baseUri/$KnowledgeEntitySetName")

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

function Test-HasKnowledgePayload {
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Payload
    )

    return ($null -ne $Payload -and $Payload.Count -gt 0)
}

function Assert-OperationRequirements {
    [CmdletBinding()]
    param()

    switch ($Operation) {
        'Get' {
            if (-not $script:HasKnowledgeSourceId) {
                throw 'KnowledgeSourceId is required when Operation is Get.'
            }
        }
        'Create' {
            if (-not (Test-HasKnowledgePayload -Payload $KnowledgeSourceData)) {
                throw 'KnowledgeSourceData is required when Operation is Create.'
            }
        }
        'Update' {
            if (-not $script:HasKnowledgeSourceId) {
                throw 'KnowledgeSourceId is required when Operation is Update.'
            }

            if (-not (Test-HasKnowledgePayload -Payload $KnowledgeSourceData)) {
                throw 'KnowledgeSourceData is required when Operation is Update.'
            }
        }
        'Delete' {
            if (-not $script:HasKnowledgeSourceId) {
                throw 'KnowledgeSourceId is required when Operation is Delete.'
            }
        }
    }
}

try {
    Assert-OperationRequirements

    $resolvedContext = Get-ValidatedCopilotContext -InputContext $Context
    $headers = New-DataverseHeaders
    $selectQuery = if ($PSBoundParameters.ContainsKey('Select')) {
        ConvertTo-SelectQueryString -Properties $Select
    }
    else {
        $null
    }

    switch ($Operation) {
        'List' {
            $requestUri = Get-KnowledgeEntityUri -ResolvedContext $resolvedContext -SelectQuery $selectQuery -FilterQuery (Get-CombinedKnowledgeFilter)
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
        'Get' {
            $requestUri = Get-KnowledgeEntityUri -ResolvedContext $resolvedContext -RecordId $KnowledgeSourceId -SelectQuery $selectQuery
            return Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'GET' -AdditionalHeaders $headers
        }
        'Create' {
            $requestUri = Get-KnowledgeEntityUri -ResolvedContext $resolvedContext
            return Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'POST' -Body $KnowledgeSourceData -ContentType 'application/json; charset=utf-8' -AdditionalHeaders $headers
        }
        'Update' {
            $requestUri = Get-KnowledgeEntityUri -ResolvedContext $resolvedContext -RecordId $KnowledgeSourceId
            $headers['If-Match'] = '*'
            Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'PATCH' -Body $KnowledgeSourceData -ContentType 'application/json; charset=utf-8' -AdditionalHeaders $headers | Out-Null

            return Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'GET' -AdditionalHeaders (New-DataverseHeaders)
        }
        'Delete' {
            $requestUri = Get-KnowledgeEntityUri -ResolvedContext $resolvedContext -RecordId $KnowledgeSourceId
            Invoke-SkillRestMethod -Uri $requestUri -AuthContext $resolvedContext -Method 'DELETE' -AdditionalHeaders $headers | Out-Null

            return [pscustomobject]@{
                Operation = 'Delete'
                KnowledgeEntitySetName = $KnowledgeEntitySetName
                KnowledgeSourceId = $KnowledgeSourceId
                AgentId = $AgentId
                Deleted = $true
            }
        }
    }
}
catch {
    $message = "Failed to perform Copilot Studio knowledge operation '$Operation'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

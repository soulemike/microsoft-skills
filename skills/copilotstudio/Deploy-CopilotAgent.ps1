#Requires -Version 7.2
<#
.SYNOPSIS
Publishes, unpublishes, or updates a Copilot Studio agent in Dataverse.

.DESCRIPTION
Uses the Dataverse bot entity that backs Copilot Studio agents. Update operations
PATCH the bot record directly. Publish and Unpublish operations support two
environment-specific patterns:

- POST to a Dataverse action endpoint when PublishActionName or
  UnpublishActionName is supplied.
- PATCH the bot record when AgentData contains the required status fields for
  the target environment.

This avoids hard-coding publish action names or statuscode mappings that can
vary across environments and solution customizations.

.PARAMETER AgentId
Required Copilot Studio agent identifier.

.PARAMETER Action
The deployment action to perform: Publish, Unpublish, or Update.

.PARAMETER AgentData
Optional hashtable used for Update operations or for Publish/Unpublish fallback
PATCH operations. This can include displayName, description, statecode,
statuscode, or other bot columns that exist in the target environment.

.PARAMETER PublishActionName
Optional Dataverse bound action name to use for Publish operations. When
specified, the script POSTs to /bots(<id>)/Microsoft.Dynamics.CRM.<ActionName>.

.PARAMETER UnpublishActionName
Optional Dataverse bound action name to use for Unpublish operations. When
specified, the script POSTs to /bots(<id>)/Microsoft.Dynamics.CRM.<ActionName>.

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
./skills/copilotstudio/Deploy-CopilotAgent.ps1 -Context $context -AgentId $agentId -Action Update -AgentData @{ name = 'Contoso Agent' }

.EXAMPLE
./skills/copilotstudio/Deploy-CopilotAgent.ps1 -Context $context -AgentId $agentId -Action Publish -PublishActionName 'PublishBot'

.EXAMPLE
./skills/copilotstudio/Deploy-CopilotAgent.ps1 -Context $context -AgentId $agentId -Action Unpublish -AgentData @{ statecode = 1; statuscode = 2 }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentId,

    [Parameter(Mandatory)]
    [ValidateSet('Publish', 'Unpublish', 'Update')]
    [string]$Action,

    [Parameter()]
    [hashtable]$AgentData,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PublishActionName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UnpublishActionName,

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

function Get-BotRecordUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedContext,

        [Parameter(Mandatory)]
        [string]$RecordId
    )

    return '{0}/bots({1})' -f $ResolvedContext.BaseUri.TrimEnd('/'), $RecordId
}

function Get-BoundActionUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedContext,

        [Parameter(Mandatory)]
        [string]$RecordId,

        [Parameter(Mandatory)]
        [string]$ActionName
    )

    return '{0}/bots({1})/Microsoft.Dynamics.CRM.{2}' -f $ResolvedContext.BaseUri.TrimEnd('/'), $RecordId, $ActionName
}

function Test-HasAgentData {
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Payload
    )

    return ($null -ne $Payload -and $Payload.Count -gt 0)
}

function Invoke-BotPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedContext,

        [Parameter(Mandatory)]
        [string]$RecordId,

        [Parameter(Mandatory)]
        [hashtable]$Payload
    )

    $headers = New-DataverseHeaders
    $headers['If-Match'] = '*'

    Invoke-SkillRestMethod -Uri (Get-BotRecordUri -ResolvedContext $ResolvedContext -RecordId $RecordId) -AuthContext $ResolvedContext -Method 'PATCH' -Body $Payload -ContentType 'application/json; charset=utf-8' -AdditionalHeaders $headers | Out-Null

    return Invoke-SkillRestMethod -Uri (Get-BotRecordUri -ResolvedContext $ResolvedContext -RecordId $RecordId) -AuthContext $ResolvedContext -Method 'GET' -AdditionalHeaders (New-DataverseHeaders)
}

function Invoke-BoundBotAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedContext,

        [Parameter(Mandatory)]
        [string]$RecordId,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [Parameter()]
        [hashtable]$Payload
    )

    $headers = New-DataverseHeaders
    $body = if (Test-HasAgentData -Payload $Payload) { $Payload } else { @{} }

    $response = Invoke-SkillRestMethod -Uri (Get-BoundActionUri -ResolvedContext $ResolvedContext -RecordId $RecordId -ActionName $ActionName) -AuthContext $ResolvedContext -Method 'POST' -Body $body -ContentType 'application/json; charset=utf-8' -AdditionalHeaders $headers
    if ($null -ne $response) {
        return $response
    }

    return Invoke-SkillRestMethod -Uri (Get-BotRecordUri -ResolvedContext $ResolvedContext -RecordId $RecordId) -AuthContext $ResolvedContext -Method 'GET' -AdditionalHeaders $headers
}

try {
    $resolvedContext = Get-ValidatedCopilotContext -InputContext $Context

    switch ($Action) {
        'Update' {
            if (-not (Test-HasAgentData -Payload $AgentData)) {
                throw 'AgentData is required when Action is Update.'
            }

            return Invoke-BotPatch -ResolvedContext $resolvedContext -RecordId $AgentId -Payload $AgentData
        }
        'Publish' {
            if ($PSBoundParameters.ContainsKey('PublishActionName')) {
                return Invoke-BoundBotAction -ResolvedContext $resolvedContext -RecordId $AgentId -ActionName $PublishActionName -Payload $AgentData
            }

            if (-not (Test-HasAgentData -Payload $AgentData)) {
                throw 'Publish requires either PublishActionName for a POST action or AgentData containing the environment-specific publish fields for a PATCH update.'
            }

            return Invoke-BotPatch -ResolvedContext $resolvedContext -RecordId $AgentId -Payload $AgentData
        }
        'Unpublish' {
            if ($PSBoundParameters.ContainsKey('UnpublishActionName')) {
                return Invoke-BoundBotAction -ResolvedContext $resolvedContext -RecordId $AgentId -ActionName $UnpublishActionName -Payload $AgentData
            }

            if (-not (Test-HasAgentData -Payload $AgentData)) {
                throw 'Unpublish requires either UnpublishActionName for a POST action or AgentData containing the environment-specific unpublish fields for a PATCH update.'
            }

            return Invoke-BotPatch -ResolvedContext $resolvedContext -RecordId $AgentId -Payload $AgentData
        }
    }
}
catch {
    $message = "Failed to execute '$Action' for Copilot Studio agent '$AgentId'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

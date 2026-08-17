#Requires -Version 7.2
<#
.SYNOPSIS
    Provisions a Log Analytics ingestion pipeline with a DCE and DCR.

.DESCRIPTION
    Creates a Data Collection Endpoint first and then creates a direct-ingestion
    Data Collection Rule that targets the supplied workspace resource ID. After
    the DCR is created, the script attempts to assign the Monitoring Metrics
    Publisher role on the DCR to the current caller identity when the access
    token exposes an oid claim.

    If role assignment cannot be created because the caller lacks
    Microsoft.Authorization/roleAssignments permission, the script emits a
    warning and still returns the DCE URI and DCR immutable ID so the caller can
    decide whether to rely on shared-key fallback.

.PARAMETER SubscriptionId
    Azure subscription ID containing the resources.

.PARAMETER ResourceGroupName
    Resource group for the DCE and DCR.

.PARAMETER WorkspaceResourceId
    Full ARM resource ID of the target Log Analytics workspace.

.PARAMETER Location
    Azure region for the DCE and DCR.

.PARAMETER DataCollectionEndpointName
    Name of the Data Collection Endpoint to create.

.PARAMETER DataCollectionRuleName
    Name of the Data Collection Rule to create.

.PARAMETER AuthContext
    ARM-capable authentication context.

.OUTPUTS
    Hashtable containing the DCE URI, DCR immutable ID, and role assignment
    details.

.EXAMPLE
    ./skills/loganalytics/New-LogAnalyticsIngestionPipeline.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceResourceId $workspaceId -Location eastus -DataCollectionEndpointName 'contoso-dce' -DataCollectionRuleName 'contoso-dcr' -AuthContext $armContext
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DataCollectionEndpointName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DataCollectionRuleName,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$dataCollectionApiVersion = '2023-03-11'
$authorizationApiVersion = '2022-04-01'
$monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
$defaultStreamName = 'Custom-LogAnalyticsRaw'
$defaultOutputStream = 'Custom-LogAnalyticsRaw_CL'

function Get-AuthEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ($Context.ContainsKey('Environment') -and -not [string]::IsNullOrWhiteSpace([string]$Context.Environment)) {
        return [string]$Context.Environment
    }

    return 'AzureCloud'
}

function Resolve-ArmAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $environment = Get-AuthEnvironment -Context $Context
    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    return (Resolve-AuthContext -AuthContext $Context -Resource ('{0}/' -f $endpoints.Arm.TrimEnd('/')))
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    if ($InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }

    return $null
}

function ConvertFrom-Base64UrlSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputString
    )

    $normalized = $InputString.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
        0 { }
        default { throw 'Invalid base64url input.' }
    }

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
}

function Get-JwtClaims {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) {
        return $null
    }

    try {
        return ConvertFrom-Base64UrlSegment -InputString $parts[1] | ConvertFrom-Json -Depth 10
    }
    catch {
        return $null
    }
}

function Get-HttpStatusCodeFromException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    if ($response.PSObject.Properties['StatusCode']) {
        $statusCode = $response.PSObject.Properties['StatusCode'].Value
        if ($statusCode -is [int]) {
            return $statusCode
        }

        if ($statusCode.PSObject.Properties['value__']) {
            return [int]$statusCode.PSObject.Properties['value__'].Value
        }
    }

    if ($ErrorRecord.Exception.Message -match 'HTTP\s+(\d{3})') {
        return [int]$Matches[1]
    }

    return $null
}

function Ensure-RoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArmEndpoint,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [string]$DcrResourceId
    )

    $jwtClaims = Get-JwtClaims -Token $ResolvedAuthContext.Token
    $principalId = if ($jwtClaims -and $jwtClaims.PSObject.Properties['oid']) {
        [string]$jwtClaims.PSObject.Properties['oid'].Value
    }
    else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Write-Warning 'Skipping Monitoring Metrics Publisher role assignment because the caller token does not expose an oid claim.'
        return [ordered]@{
            Attempted = $false
            Applied = $false
            PrincipalId = $null
            RoleDefinitionId = $null
            Status = 'SkippedNoPrincipalId'
        }
    }

    $roleDefinitionId = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $SubscriptionId, $monitoringMetricsPublisherRoleId
    $assignmentUri = '{0}{1}/providers/Microsoft.Authorization/roleAssignments/{2}?api-version={3}' -f `
        $ArmEndpoint,
        $DcrResourceId,
        ([guid]::NewGuid().Guid),
        $authorizationApiVersion

    $assignmentBody = @{
        properties = @{
            roleDefinitionId = $roleDefinitionId
            principalId = $principalId
            principalType = 'ServicePrincipal'
        }
    }

    try {
        $null = Invoke-SkillRestMethod -Uri $assignmentUri -AuthContext $ResolvedAuthContext -Method 'PUT' -Body $assignmentBody
        return [ordered]@{
            Attempted = $true
            Applied = $true
            PrincipalId = $principalId
            RoleDefinitionId = $roleDefinitionId
            Status = 'Created'
        }
    }
    catch {
        $statusCode = Get-HttpStatusCodeFromException -ErrorRecord $_
        if ($statusCode -eq 409) {
            return [ordered]@{
                Attempted = $true
                Applied = $true
                PrincipalId = $principalId
                RoleDefinitionId = $roleDefinitionId
                Status = 'AlreadyExists'
            }
        }

        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Write-Warning 'The DCR was created, but the Monitoring Metrics Publisher role assignment could not be applied. The caller appears to lack Microsoft.Authorization/roleAssignments permission. DCR ingestion may return 401 or 403 until the role is granted. The shared-key Data Collector API fallback remains available when a workspace shared key is provided.'
            return [ordered]@{
                Attempted = $true
                Applied = $false
                PrincipalId = $principalId
                RoleDefinitionId = $roleDefinitionId
                Status = 'InsufficientRoleAssignmentPermissions'
            }
        }

        throw
    }
}

try {
    $resolvedAuthContext = Resolve-ArmAuthContext -Context $AuthContext
    $armEndpoint = (Get-EnvironmentEndpoints -Environment (Get-AuthEnvironment -Context $AuthContext)).Arm.TrimEnd('/')

    $dceUri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Insights/dataCollectionEndpoints/{3}?api-version={4}' -f `
        $armEndpoint,
        [System.Uri]::EscapeDataString($SubscriptionId),
        [System.Uri]::EscapeDataString($ResourceGroupName),
        [System.Uri]::EscapeDataString($DataCollectionEndpointName),
        [System.Uri]::EscapeDataString($dataCollectionApiVersion)

    $dceBody = @{
        location = $Location
        properties = @{
            networkAcls = @{
                publicNetworkAccess = 'Enabled'
            }
        }
    }

    $null = Invoke-SkillRestMethod -Uri $dceUri -AuthContext $resolvedAuthContext -Method 'PUT' -Body $dceBody
    $dceResponse = Invoke-SkillRestMethod -Uri $dceUri -AuthContext $resolvedAuthContext -Method 'GET'
    $dceProperties = Get-ObjectPropertyValue -InputObject $dceResponse -Name 'properties'
    $logsIngestionProperty = Get-ObjectPropertyValue -InputObject $dceProperties -Name 'logsIngestion'
    $dceLogsIngestionEndpoint = Get-ObjectPropertyValue -InputObject $logsIngestionProperty -Name 'endpoint'
    $dceResourceId = Get-ObjectPropertyValue -InputObject $dceResponse -Name 'id'

    $dcrUri = '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Insights/dataCollectionRules/{3}?api-version={4}' -f `
        $armEndpoint,
        [System.Uri]::EscapeDataString($SubscriptionId),
        [System.Uri]::EscapeDataString($ResourceGroupName),
        [System.Uri]::EscapeDataString($DataCollectionRuleName),
        [System.Uri]::EscapeDataString($dataCollectionApiVersion)

    $dcrBody = @{
        location = $Location
        kind = 'Direct'
        properties = @{
            dataCollectionEndpointId = $dceResourceId
            streamDeclarations = @{
                $defaultStreamName = @{
                    columns = @(
                        @{ name = 'TimeGenerated'; type = 'datetime' }
                        @{ name = 'RawData'; type = 'string' }
                    )
                }
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        name = 'workspaceDestination'
                        workspaceResourceId = $WorkspaceResourceId
                    }
                )
            }
            dataFlows = @(
                @{
                    streams = @($defaultStreamName)
                    destinations = @('workspaceDestination')
                    transformKql = 'source'
                    outputStream = $defaultOutputStream
                }
            )
        }
    }

    $null = Invoke-SkillRestMethod -Uri $dcrUri -AuthContext $resolvedAuthContext -Method 'PUT' -Body $dcrBody
    $dcrResponse = Invoke-SkillRestMethod -Uri $dcrUri -AuthContext $resolvedAuthContext -Method 'GET'
    $dcrProperties = Get-ObjectPropertyValue -InputObject $dcrResponse -Name 'properties'
    $immutableId = Get-ObjectPropertyValue -InputObject $dcrProperties -Name 'immutableId'
    $dcrResourceId = Get-ObjectPropertyValue -InputObject $dcrResponse -Name 'id'
    $roleAssignment = Ensure-RoleAssignment -ArmEndpoint $armEndpoint -ResolvedAuthContext $resolvedAuthContext -DcrResourceId $dcrResourceId

    return [ordered]@{
        DceUri = $dceLogsIngestionEndpoint
        DceResourceId = $dceResourceId
        DcrImmutableId = $immutableId
        DcrResourceId = $dcrResourceId
        DefaultStreamName = $defaultStreamName
        DefaultOutputStream = $defaultOutputStream
        RoleAssignment = $roleAssignment
    }
}
catch {
    $message = "Failed to provision the Log Analytics ingestion pipeline. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

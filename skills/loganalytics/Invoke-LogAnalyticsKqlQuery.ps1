#Requires -Version 7.2
<#
.SYNOPSIS
Executes a Log Analytics KQL query.

.DESCRIPTION
Runs a KQL query against a Log Analytics workspace by using the Log Analytics data-plane
query endpoint. The script resolves the correct Log Analytics endpoint for the
configured Azure environment, submits the query payload, and converts tabular query
results into PowerShell objects.

KQL-specific service errors are normalized into clearer PowerShell exceptions to make
query troubleshooting easier.

.PARAMETER WorkspaceId
The Log Analytics workspace ID to query.

.PARAMETER Query
The KQL query string to execute.

.PARAMETER Timespan
Optional query timespan such as 1h, 24h, or 7d.

.PARAMETER AuthContext
An authentication context hashtable returned by the project's authentication helpers.

.EXAMPLE
./Invoke-LogAnalyticsKqlQuery.ps1 `
    -WorkspaceId "00000000-0000-0000-0000-000000000000" `
    -Query "SecurityIncident | take 10" `
    -Timespan "1d" `
    -AuthContext $authContext

.OUTPUTS
System.Management.Automation.PSCustomObject
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Query,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Timespan,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

function Convert-LogAnalyticsTableToObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Table,

        [Parameter()]
        [switch]$IncludeTableMetadata
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $columns = @($Table.columns)

    foreach ($row in @($Table.rows)) {
        $properties = [ordered]@{}

        for ($index = 0; $index -lt $columns.Count; $index++) {
            $columnName = $columns[$index].name
            $properties[$columnName] = if ($index -lt $row.Count) { $row[$index] } else { $null }
        }

        if ($IncludeTableMetadata) {
            $properties['__TableName'] = $Table.name
            $properties['__TableKind'] = $Table.kind
        }

        $rows.Add([pscustomobject]$properties)
    }

    return $rows
}

function Get-KqlErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $detailMessage = if ($ErrorRecord.PSObject.Properties['ErrorDetails'] -and $ErrorRecord.ErrorDetails.PSObject.Properties['Message']) {
        $ErrorRecord.ErrorDetails.Message
    }
    else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($detailMessage)) {
        return $ErrorRecord.Exception.Message
    }

    try {
        $parsedDetail = $detailMessage | ConvertFrom-Json -ErrorAction Stop
        if ($parsedDetail.PSObject.Properties['error']) {
            $serviceError = $parsedDetail.error
            $message = if ($serviceError.PSObject.Properties['message']) { $serviceError.message } else { $null }
            if ($serviceError.PSObject.Properties['code'] -and $message) {
                return "$($serviceError.code): $message"
            }

            if ($message) {
                return $message
            }
        }
    }
    catch {
        # Fall back to the raw detail message when the service did not return JSON.
    }

    return $detailMessage
}

try {
    $environment = if ($AuthContext.ContainsKey('Environment') -and $AuthContext.Environment) {
        $AuthContext.Environment
    }
    else {
        'AzureCloud'
    }

    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    # Token audience (api.loganalytics.io) differs from request endpoint (api.loganalytics.azure.com)
    $resolvedAuthContext = Resolve-AuthContext -AuthContext $AuthContext -Resource $endpoints.LogAnalyticsTokenAudience

    $uri = '{0}/v1/workspaces/{1}/query' -f $endpoints.LogAnalytics.TrimEnd('/'), $WorkspaceId

    $body = [ordered]@{
        query = $Query
    }

    if ($PSBoundParameters.ContainsKey('Timespan')) {
        $body.timespan = $Timespan
    }

    $response = Invoke-SkillRestMethod -Uri $uri -Method 'POST' -Body $body -AuthContext $resolvedAuthContext

    if ($response.PSObject.Properties['error']) {
        $errorObj = $response.error
        $errorCode = if ($errorObj.PSObject.Properties['code']) { $errorObj.code } else { $null }
        $errorMessage = if ($errorObj.PSObject.Properties['message']) { $errorObj.message } else { $null }

        $message = if ($errorCode -and $errorMessage) {
            "$errorCode`: $errorMessage"
        }
        elseif ($errorMessage) {
            $errorMessage
        }
        else {
            $errorObj | ConvertTo-Json -Depth 3
        }

        throw "Log Analytics KQL query failed. $message"
    }

    $tables = @($response.tables)
    if ($tables.Count -eq 0) {
        return @()
    }

    $includeTableMetadata = $tables.Count -gt 1
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($table in $tables) {
        $tableRows = Convert-LogAnalyticsTableToObjects -Table $table -IncludeTableMetadata:$includeTableMetadata
        foreach ($tableRow in $tableRows) {
            $results.Add($tableRow)
        }
    }

    return $results
}
catch {
    $message = Get-KqlErrorMessage -ErrorRecord $_
    throw "Failed to execute Log Analytics KQL query against workspace '$WorkspaceId'. $message"
}

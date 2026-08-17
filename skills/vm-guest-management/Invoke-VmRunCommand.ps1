#Requires -Version 7.2
<#
.SYNOPSIS
    Runs a guest script on an Azure VM or Azure Arc-enabled machine.

.DESCRIPTION
    Wraps Azure VM Run Command and Azure Arc Run Command operations by using the
    project's shared authentication and REST helpers from Common.psm1.

    The script supports two execution patterns:
    - Action Run Command for Azure virtual machines via POST .../runCommand
    - Managed Run Command resources via PUT .../runCommands/{name}

    Managed Run Command is the preferred production pattern because it supports
    explicit timeout handling, durable ARM resources, and optional output/error
    blob streaming. The script never treats provisioningState alone as proof of
    guest success. For managed executions it inspects instanceView.executionState,
    instanceView.exitCode, instanceView.output, and instanceView.error.

    Azure Arc uses the Microsoft.HybridCompute provider. Arc Run Command follows
    the managed-resource model, so -RunCommandName is required when -IsArc is
    specified.

.PARAMETER ResourceGroupName
    Azure resource group that contains the target VM or Arc-enabled machine.

.PARAMETER VmName
    Azure virtual machine name.

.PARAMETER MachineName
    Azure Arc-enabled machine name.

.PARAMETER ScriptString
    Inline script content to execute.

.PARAMETER ScriptPath
    Path to a local script file. The file content is uploaded as inline script
    content for the guest execution request.

.PARAMETER RunCommandName
    Optional managed Run Command resource name. When provided, the script uses a
    PUT request against the Run Command ARM resource instead of the action POST.

.PARAMETER TimeoutInSeconds
    Guest execution timeout in seconds. Defaults to 1800.

.PARAMETER OutputBlobUri
    Optional SAS URI for full standard output capture when using managed Run
    Command.

.PARAMETER ErrorBlobUri
    Optional SAS URI for full standard error capture when using managed Run
    Command.

.PARAMETER TreatFailureAsDeploymentFailure
    For managed Run Command, requests ARM to surface guest execution failure as
    a deployment failure when supported by the API version.

.PARAMETER IsArc
    Uses Microsoft.HybridCompute/machines instead of
    Microsoft.Compute/virtualMachines.

.PARAMETER AuthContext
    Azure ARM authentication context returned by Connect-AzureApi.ps1.

.OUTPUTS
    PSCustomObject

.EXAMPLE
    ./skills/vm-guest-management/Invoke-VmRunCommand.ps1 \
        -ResourceGroupName 'rg-app' \
        -VmName 'vm01' \
        -ScriptString 'uname -a' \
        -AuthContext $context

.EXAMPLE
    ./skills/vm-guest-management/Invoke-VmRunCommand.ps1 \
        -ResourceGroupName 'rg-app' \
        -MachineName 'arc01' \
        -RunCommandName 'bootstrap' \
        -ScriptPath './bootstrap.ps1' \
        -IsArc \
        -TreatFailureAsDeploymentFailure \
        -AuthContext $context
#>
[CmdletBinding(DefaultParameterSetName = 'VmName')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(ParameterSetName = 'VmName')]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [Parameter(ParameterSetName = 'MachineName')]
    [ValidateNotNullOrEmpty()]
    [string]$MachineName,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ScriptString,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RunCommandName,

    [Parameter()]
    [ValidateRange(1, 5400)]
    [int]$TimeoutInSeconds = 1800,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputBlobUri,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ErrorBlobUri,

    [Parameter()]
    [switch]$TreatFailureAsDeploymentFailure,

    [Parameter()]
    [switch]$IsArc,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$AuthContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'Common.psm1') -Force -ErrorAction Stop

$script:HasScriptString = $PSBoundParameters.ContainsKey('ScriptString')
$script:HasScriptPath = $PSBoundParameters.ContainsKey('ScriptPath')
$script:HasOutputBlobUri = $PSBoundParameters.ContainsKey('OutputBlobUri')
$script:HasErrorBlobUri = $PSBoundParameters.ContainsKey('ErrorBlobUri')

$script:ComputeActionApiVersion = '2025-11-01'
$script:ComputeManagedApiVersion = '2024-03-01'
$script:HybridComputeManagedApiVersion = '2025-01-13'
$script:PollIntervalSeconds = 5

function ConvertTo-AuthHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($InputObject -is [hashtable]) {
        return @{} + $InputObject
    }

    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }

    return $table
}

function Get-RequiredTargetName {
    [CmdletBinding()]
    param()

    if ($IsArc) {
        if ([string]::IsNullOrWhiteSpace($MachineName)) {
            throw 'When -IsArc is specified, -MachineName is required.'
        }

        return $MachineName
    }

    if ([string]::IsNullOrWhiteSpace($VmName)) {
        throw 'When -IsArc is not specified, -VmName is required.'
    }

    return $VmName
}

function Get-ScriptContent {
    [CmdletBinding()]
    param()

    $hasScriptString = $script:HasScriptString
    $hasScriptPath = $script:HasScriptPath

    if (($hasScriptString -and $hasScriptPath) -or (-not $hasScriptString -and -not $hasScriptPath)) {
        throw 'Specify exactly one of -ScriptString or -ScriptPath.'
    }

    if ($hasScriptPath) {
        if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
            throw "ScriptPath was not found: $ScriptPath"
        }

        return Get-Content -Path $ScriptPath -Raw
    }

    return $ScriptString
}

function Get-HeaderValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]$key -ieq $Name) {
                $value = $Headers[$key]
                if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                    return (@($value) -join ', ')
                }

                return [string]$value
            }
        }

        return $null
    }

    foreach ($property in $Headers.PSObject.Properties) {
        if ($property.Name -ieq $Name) {
            if ($property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [string]) {
                return (@($property.Value) -join ', ')
            }

            return [string]$property.Value
        }
    }

    return $null
}

function ConvertTo-ResponseHeaderObject {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Headers
    )

    if ($null -eq $Headers) {
        return $null
    }

    $result = [ordered]@{}
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            $result[[string]$key] = Get-HeaderValue -Headers $Headers -Name ([string]$key)
        }
    }
    else {
        foreach ($property in $Headers.PSObject.Properties) {
            $result[$property.Name] = Get-HeaderValue -Headers $Headers -Name $property.Name
        }
    }

    return [pscustomobject]$result
}

function Invoke-ArmRequestWithMeta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter()]
        [AllowNull()]
        [object]$Body,

        [Parameter()]
        [string]$ContentType = 'application/json'
    )

    $responseHeaders = $null
    $statusCode = $null
    $savedDefaults = @{}
    $defaultKeys = @(
        'Invoke-RestMethod:ResponseHeadersVariable'
        'Invoke-RestMethod:StatusCodeVariable'
    )

    foreach ($key in $defaultKeys) {
        if ($PSDefaultParameterValues.ContainsKey($key)) {
            $savedDefaults[$key] = $PSDefaultParameterValues[$key]
        }
    }

    try {
        $PSDefaultParameterValues['Invoke-RestMethod:ResponseHeadersVariable'] = 'responseHeaders'
        $PSDefaultParameterValues['Invoke-RestMethod:StatusCodeVariable'] = 'statusCode'

        $requestParams = @{
            Uri = $Uri
            Method = $Method
            AuthContext = $ResolvedAuthContext
            ContentType = $ContentType
        }

        if ($PSBoundParameters.ContainsKey('Body')) {
            $requestParams.Body = $Body
        }

        $value = Invoke-SkillRestMethod @requestParams

        return [pscustomobject][ordered]@{
            StatusCode = $statusCode
            Headers = ConvertTo-ResponseHeaderObject -Headers $responseHeaders
            Value = $value
        }
    }
    finally {
        foreach ($key in $defaultKeys) {
            if ($savedDefaults.ContainsKey($key)) {
                $PSDefaultParameterValues[$key] = $savedDefaults[$key]
            }
            else {
                $null = $PSDefaultParameterValues.Remove($key)
            }
        }
    }
}

function Get-EnvironmentFromAuthContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    if ($ResolvedAuthContext.ContainsKey('Environment') -and -not [string]::IsNullOrWhiteSpace([string]$ResolvedAuthContext.Environment)) {
        return [string]$ResolvedAuthContext.Environment
    }

    return 'AzureCloud'
}

function Get-ArmSubscriptionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    if ($ResolvedAuthContext.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace([string]$ResolvedAuthContext.SubscriptionId)) {
        return [string]$ResolvedAuthContext.SubscriptionId
    }

    throw 'AuthContext.SubscriptionId is required for VM guest management operations.'
}

function Get-RunCommandApiVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Managed,

        [Parameter(Mandatory)]
        [bool]$Arc
    )

    if ($Arc) {
        return $script:HybridComputeManagedApiVersion
    }

    if ($Managed) {
        return $script:ComputeManagedApiVersion
    }

    return $script:ComputeActionApiVersion
}

function Get-TargetDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext
    )

    if ($IsArc) {
        $uri = (
            '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.HybridCompute/machines/{3}?api-version={4}' -f
            $ArmBaseUri.TrimEnd('/'),
            $SubscriptionId,
            $ResourceGroupName,
            $TargetName,
            $script:HybridComputeManagedApiVersion
        )

        $resource = Invoke-SkillRestMethod -Uri $uri -AuthContext $ResolvedAuthContext -Method 'GET'

        return [pscustomobject][ordered]@{
            ResourceId = $resource.id
            Location = $resource.location
            OsType = if ($resource.properties.osType) { [string]$resource.properties.osType } else { $null }
            Provider = 'Microsoft.HybridCompute'
            ResourceType = 'machines'
        }
    }

    $uri = (
        '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}?api-version={4}' -f
        $ArmBaseUri.TrimEnd('/'),
        $SubscriptionId,
        $ResourceGroupName,
        $TargetName,
        $script:ComputeManagedApiVersion
    )

    $resource = Invoke-SkillRestMethod -Uri $uri -AuthContext $ResolvedAuthContext -Method 'GET'

    return [pscustomobject][ordered]@{
        ResourceId = $resource.id
        Location = $resource.location
        OsType = if ($resource.properties.storageProfile.osDisk.osType) { [string]$resource.properties.storageProfile.osDisk.osType } else { $null }
        Provider = 'Microsoft.Compute'
        ResourceType = 'virtualMachines'
    }
}

function ConvertTo-ScriptLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n", 0, [System.StringSplitOptions]::None)
    if ($lines.Count -eq 0) {
        return @('')
    }

    return $lines
}

function Get-ManagedResourceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArmBaseUri,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter(Mandatory)]
        [string]$ApiVersion
    )

    $providerNamespace = if ($IsArc) { 'Microsoft.HybridCompute' } else { 'Microsoft.Compute' }
    $resourceType = if ($IsArc) { 'machines' } else { 'virtualMachines' }

    return (
        '{0}/subscriptions/{1}/resourceGroups/{2}/providers/{3}/{4}/{5}/runCommands/{6}?api-version={7}' -f
        $ArmBaseUri.TrimEnd('/'),
        $SubscriptionId,
        $ResourceGroupName,
        $providerNamespace,
        $resourceType,
        $TargetName,
        $RunCommandName,
        $ApiVersion
    )
}

function Get-ManagedInstanceViewUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManagedResourceUri
    )

    if ($ManagedResourceUri -match '([?&])\$expand=') {
        return $ManagedResourceUri
    }

    $separator = if ($ManagedResourceUri.Contains('?')) { '&' } else { '?' }
    return "$ManagedResourceUri${separator}`$expand=instanceView"
}

function Get-TerminalProvisioningState {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$State
    )

    return @('Succeeded', 'Failed', 'Canceled') -contains $State
}

function Get-TerminalExecutionState {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$State
    )

    return @('Succeeded', 'Failed', 'TimedOut', 'Canceled') -contains $State
}

function ConvertTo-ManagedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$RunCommandResource,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter(Mandatory)]
        [bool]$Arc
    )

    $properties = $RunCommandResource.properties
    $instanceView = $properties.instanceView
    $executionState = if ($null -ne $instanceView -and $null -ne $instanceView.executionState) { [string]$instanceView.executionState } else { $null }
    $exitCode = if ($null -ne $instanceView -and $null -ne $instanceView.exitCode) { [int]$instanceView.exitCode } else { $null }
    $output = if ($null -ne $instanceView -and $null -ne $instanceView.output) { [string]$instanceView.output } else { $null }
    $errorText = if ($null -ne $instanceView -and $null -ne $instanceView.error) { [string]$instanceView.error } else { $null }

    return [pscustomobject][ordered]@{
        TargetName = $TargetName
        ResourceGroupName = $ResourceGroupName
        IsArc = $Arc
        Mode = 'Managed'
        RunCommandName = $RunCommandResource.name
        ResourceId = $RunCommandResource.id
        ProvisioningState = [string]$properties.provisioningState
        ExecutionState = $executionState
        ExitCode = $exitCode
        Output = $output
        Error = $errorText
        ExecutionMessage = if ($null -ne $instanceView -and $instanceView.executionMessage) { [string]$instanceView.executionMessage } else { $null }
        StartTime = if ($null -ne $instanceView -and $instanceView.startTime) { $instanceView.startTime } else { $null }
        EndTime = if ($null -ne $instanceView -and $instanceView.endTime) { $instanceView.endTime } else { $null }
        OutputBlobUri = if ($properties.outputBlobUri) { [string]$properties.outputBlobUri } else { $null }
        ErrorBlobUri = if ($properties.errorBlobUri) { [string]$properties.errorBlobUri } else { $null }
        Succeeded = ($executionState -eq 'Succeeded' -and ($null -eq $exitCode -or $exitCode -eq 0))
    }
}

function ConvertTo-ActionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ResponseBody,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter()]
        [AllowNull()]
        [string]$FallbackState
    )

    $exitCode = $null
    $output = $null
    $errorText = $null
    $executionState = $null
    $executionMessage = $null

    if ($ResponseBody -and $ResponseBody.value) {
        $messages = @($ResponseBody.value)
        if ($messages.Count -gt 0 -and $messages[0].message) {
            $executionMessage = [string]$messages[0].message
            try {
                $parsed = $executionMessage | ConvertFrom-Json -Depth 20
                if ($parsed.PSObject.Properties.Name -contains 'exitCode') {
                    $exitCode = [int]$parsed.exitCode
                }

                if ($parsed.PSObject.Properties.Name -contains 'output') {
                    $output = [string]$parsed.output
                }

                if ($parsed.PSObject.Properties.Name -contains 'error') {
                    $errorText = [string]$parsed.error
                }

                if ($parsed.PSObject.Properties.Name -contains 'executionState') {
                    $executionState = [string]$parsed.executionState
                }

                if (-not $output -and $parsed.PSObject.Properties.Name -contains 'message') {
                    $output = [string]$parsed.message
                }
            }
            catch {
                $output = $executionMessage
            }
        }
    }

    if (-not $executionState) {
        if ($FallbackState) {
            $executionState = $FallbackState
        }
        elseif ($null -ne $exitCode) {
            $executionState = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
        }
        else {
            $executionState = 'Succeeded'
        }
    }

    if (-not $errorText -and $executionState -in @('Failed', 'Canceled') -and $executionMessage) {
        $errorText = $executionMessage
    }

    if (-not $output -and $executionState -eq 'Succeeded' -and $executionMessage) {
        $output = $executionMessage
    }

    return [pscustomobject][ordered]@{
        TargetName = $TargetName
        ResourceGroupName = $ResourceGroupName
        IsArc = $false
        Mode = 'Action'
        RunCommandName = $null
        ResourceId = $null
        ProvisioningState = $executionState
        ExecutionState = $executionState
        ExitCode = $exitCode
        Output = $output
        Error = $errorText
        ExecutionMessage = $executionMessage
        StartTime = $null
        EndTime = $null
        OutputBlobUri = $null
        ErrorBlobUri = $null
        Succeeded = ($executionState -eq 'Succeeded' -and ($null -eq $exitCode -or $exitCode -eq 0))
    }
}

function Wait-ForManagedRunCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManagedResourceUri,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [datetime]$Deadline,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter(Mandatory)]
        [bool]$Arc
    )

    $instanceViewUri = Get-ManagedInstanceViewUri -ManagedResourceUri $ManagedResourceUri

    do {
        $resource = Invoke-SkillRestMethod -Uri $instanceViewUri -AuthContext $ResolvedAuthContext -Method 'GET'
        $result = ConvertTo-ManagedResult -RunCommandResource $resource -TargetName $TargetName -Arc $Arc

        if (Get-TerminalExecutionState -State $result.ExecutionState) {
            return $result
        }

        if (($result.ProvisioningState -in @('Failed', 'Canceled')) -and -not $result.ExecutionState) {
            return $result
        }

        if ((Get-Date) -ge $Deadline) {
            throw "Timed out while waiting for managed Run Command '$RunCommandName' on '$TargetName'."
        }

        Start-Sleep -Seconds $script:PollIntervalSeconds
    }
    while ($true)
}

function Wait-ForActionCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InitialResponse,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedAuthContext,

        [Parameter(Mandatory)]
        [datetime]$Deadline,

        [Parameter(Mandatory)]
        [string]$TargetName
    )

    if ($InitialResponse.StatusCode -eq 200 -or $InitialResponse.StatusCode -eq 201) {
        return ConvertTo-ActionResult -ResponseBody $InitialResponse.Value -TargetName $TargetName -FallbackState 'Succeeded'
    }

    $pollUri = Get-HeaderValue -Headers $InitialResponse.Headers -Name 'Azure-AsyncOperation'
    if (-not $pollUri) {
        $pollUri = Get-HeaderValue -Headers $InitialResponse.Headers -Name 'Operation-Location'
    }

    if (-not $pollUri) {
        $pollUri = Get-HeaderValue -Headers $InitialResponse.Headers -Name 'Location'
    }

    if (-not $pollUri) {
        return ConvertTo-ActionResult -ResponseBody $InitialResponse.Value -TargetName $TargetName -FallbackState 'Succeeded'
    }

    do {
        $pollResponse = Invoke-SkillRestMethod -Uri $pollUri -AuthContext $ResolvedAuthContext -Method 'GET'

        $status = $null
        if ($pollResponse.status) {
            $status = [string]$pollResponse.status
        }
        elseif ($pollResponse.properties.provisioningState) {
            $status = [string]$pollResponse.properties.provisioningState
        }

        if ($status -in @('Succeeded', 'Failed', 'Canceled')) {
            return ConvertTo-ActionResult -ResponseBody $pollResponse -TargetName $TargetName -FallbackState $status
        }

        if ((Get-Date) -ge $Deadline) {
            throw "Timed out while waiting for action Run Command completion on '$TargetName'."
        }

        Start-Sleep -Seconds $script:PollIntervalSeconds
    }
    while ($true)
}

try {
    if ($IsArc -and -not $RunCommandName) {
        throw 'Azure Arc Run Command is resource-based. Specify -RunCommandName when using -IsArc.'
    }

    $targetName = Get-RequiredTargetName
    $scriptContent = Get-ScriptContent
    $resolvedAuthContext = ConvertTo-AuthHashtable -InputObject $AuthContext
    $environment = Get-EnvironmentFromAuthContext -ResolvedAuthContext $resolvedAuthContext
    $endpoints = Get-EnvironmentEndpoints -Environment $environment
    $resolvedAuthContext = Resolve-AuthContext -AuthContext $resolvedAuthContext -Resource "$($endpoints.Arm)/"
    $subscriptionId = Get-ArmSubscriptionId -ResolvedAuthContext $resolvedAuthContext
    $targetMetadata = Get-TargetDetail -ArmBaseUri $endpoints.Arm -SubscriptionId $subscriptionId -TargetName $targetName -ResolvedAuthContext $resolvedAuthContext
    $deadline = (Get-Date).AddSeconds($TimeoutInSeconds + 120)

    if ($RunCommandName) {
        $managedApiVersion = Get-RunCommandApiVersion -Managed $true -Arc $IsArc.IsPresent
        $managedUri = Get-ManagedResourceUri -ArmBaseUri $endpoints.Arm -SubscriptionId $subscriptionId -TargetName $targetName -ApiVersion $managedApiVersion

        $bodyProperties = [ordered]@{
            source = @{ script = $scriptContent }
            asyncExecution = $false
            timeoutInSeconds = $TimeoutInSeconds
        }

        if ($script:HasOutputBlobUri) {
            $bodyProperties.outputBlobUri = $OutputBlobUri
        }

        if ($script:HasErrorBlobUri) {
            $bodyProperties.errorBlobUri = $ErrorBlobUri
        }

        if ($TreatFailureAsDeploymentFailure.IsPresent) {
            $bodyProperties.treatFailureAsDeploymentFailure = $true
        }

        $managedBody = [ordered]@{
            location = $targetMetadata.Location
            properties = $bodyProperties
        }

        $null = Invoke-ArmRequestWithMeta -Uri $managedUri -Method 'PUT' -ResolvedAuthContext $resolvedAuthContext -Body $managedBody
        return Wait-ForManagedRunCommand -ManagedResourceUri $managedUri -ResolvedAuthContext $resolvedAuthContext -Deadline $deadline -TargetName $targetName -Arc $IsArc.IsPresent
    }

    if ($IsArc) {
        throw 'Action Run Command is only supported for Azure virtual machines in this wrapper. Use -RunCommandName for Azure Arc.'
    }

    $commandId = if ($targetMetadata.OsType -eq 'Windows') { 'RunPowerShellScript' } else { 'RunShellScript' }
    $actionBody = [ordered]@{
        commandId = $commandId
        script = @(ConvertTo-ScriptLine -Content $scriptContent)
    }

    $actionUri = (
        '{0}/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}/runCommand?api-version={4}' -f
        $endpoints.Arm.TrimEnd('/'),
        $subscriptionId,
        $ResourceGroupName,
        $targetName,
        (Get-RunCommandApiVersion -Managed $false -Arc $false)
    )

    $response = Invoke-ArmRequestWithMeta -Uri $actionUri -Method 'POST' -ResolvedAuthContext $resolvedAuthContext -Body $actionBody
    return Wait-ForActionCompletion -InitialResponse $response -ResolvedAuthContext $resolvedAuthContext -Deadline $deadline -TargetName $targetName
}
catch {
    $targetDisplayName = if ($IsArc) { $MachineName } else { $VmName }
    $message = "Failed to invoke guest Run Command for '$targetDisplayName' in resource group '$ResourceGroupName'. $($_.Exception.Message)"
    throw [System.InvalidOperationException]::new($message, $_.Exception)
}

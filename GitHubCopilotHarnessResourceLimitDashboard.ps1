<#
.SYNOPSIS
Dashboard and command-line helper for limiting newly created GitHub Copilot harness resources.

.DESCRIPTION
Loads the existing PP_CopilotstudioResourcelimitmanager.ps1 API/update functions, filters
Copilot Studio billable resources to GitHub Copilot harness CLI agents and related workflows
created in the selected date range, and sets their desired message limit to zero or to the
provided LimitValue.

.EXAMPLE
.\GitHubCopilotHarnessResourceLimitDashboard.ps1

.EXAMPLE
.\GitHubCopilotHarnessResourceLimitDashboard.ps1 -Range Today -LimitValue 0

.EXAMPLE
.\GitHubCopilotHarnessResourceLimitDashboard.ps1 -Range Last7Days -LimitValue 25 -AutoSet -WhatIf

.EXAMPLE
.\GitHubCopilotHarnessResourceLimitDashboard.ps1 -Range Last7Days -LimitValue 0
# Loads matching agents and workflows from all environments.

.EXAMPLE
.\GitHubCopilotHarnessResourceLimitDashboard.ps1 -RunMode ScheduledJob -Range Today -LimitValue 0 -AuditCsvPath "C:\Logs\github-copilot-harness-resource-limits.csv"
# Scheduled-job mode loads matching resources, exports an audit CSV, and applies the limit without showing the GUI.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Today", "Last7Days", "Custom")]
    [string] $Range = "Last7Days",

    [Parameter(Mandatory = $false)]
    [datetime] $StartDate = (Get-Date).Date.AddDays(-6),

    [Parameter(Mandatory = $false)]
    [datetime] $EndDate = (Get-Date).Date,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $LimitValue = 0,

    [Parameter(Mandatory = $false)]
    [bool] $StopUsageAtLimit = $true,

    [Parameter(Mandatory = $false)]
    [switch] $EnablePvaBillingFallback,

    [Parameter(Mandatory = $false)]
    [string] $BaselinePath = (Join-Path $PSScriptRoot "PP_CopilotstudioResourcelimitmanager.ps1"),

    [Parameter(Mandatory = $false)]
    [string] $AuditCsvPath = (Join-Path $PSScriptRoot "github-copilot-harness-resource-limits.csv"),

    [Parameter(Mandatory = $false)]
    [string] $EntitlementId = "MCSMessages",

    [Parameter(Mandatory = $false)]
    [string] $AdminApiClientId = "",

    [Parameter(Mandatory = $false)]
    [string] $EnvironmentId = "",

    [Parameter(Mandatory = $false)]
    [string] $HarnessTextPattern = "(?i)(github\s*copilot|github|ghcp|cli\s*agent|cliagent|copilot\s*harness)",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Gui", "ScheduledJob")]
    [string] $RunMode = "Gui",

    [Parameter(Mandatory = $false)]
    [switch] $AutoSet,

    [Parameter(Mandatory = $false)]
    [switch] $NoDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-HarnessDateRange {
    param(
        [Parameter(Mandatory = $true)][string] $SelectedRange,
        [Parameter(Mandatory = $true)][datetime] $CustomStartDate,
        [Parameter(Mandatory = $true)][datetime] $CustomEndDate
    )

    $today = (Get-Date).Date
    switch ($SelectedRange) {
        "Today" {
            $start = $today
            $end = $today
        }
        "Last7Days" {
            $start = $today.AddDays(-6)
            $end = $today
        }
        default {
            $start = $CustomStartDate.Date
            $end = $CustomEndDate.Date
        }
    }

    if ($start -gt $end) {
        throw "Start date must be earlier than or equal to end date."
    }

    [pscustomobject]@{
        Start = $start
        End   = $end.Date.AddDays(1).AddTicks(-1)
    }
}

function Get-BaselineSource {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Baseline script not found: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path)
    $cutIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ne "Ensure-RequiredModules") {
            continue
        }

        $nextNonBlank = ""
        for ($lookAhead = $index + 1; $lookAhead -lt $lines.Count; $lookAhead++) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$lookAhead])) {
                $nextNonBlank = $lines[$lookAhead].Trim()
                break
            }
        }

        if ($nextNonBlank -eq "Show-CopilotStudioResourceLimitManager") {
            $cutIndex = $index
            break
        }
    }

    if ($cutIndex -lt 0) {
        throw "Could not find dashboard launch block in baseline script: $Path"
    }

    return ($lines[0..($cutIndex - 1)] -join [Environment]::NewLine)
}

$resolvedRange = Resolve-HarnessDateRange -SelectedRange $Range -CustomStartDate $StartDate -CustomEndDate $EndDate
$baselineSource = Get-BaselineSource -Path $BaselinePath
$baselineLoader = [scriptblock]::Create($baselineSource)
. $baselineLoader -Path $AuditCsvPath -EntitlementId $EntitlementId -FromDate $resolvedRange.Start.Date -ToDate $resolvedRange.End.Date -AdminApiClientId $AdminApiClientId

$script:HarnessResourceMetadataCache = @{}
$script:HarnessGridTable = $null

function ConvertTo-HarnessDateTime {
    param([Parameter(Mandatory = $false)][object] $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return $null
    }

    if ($Value -is [datetime]) {
        return [datetime]$Value
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) {
        return $parsed
    }

    return $null
}

function Get-FirstCreatedDateValue {
    param([Parameter(Mandatory = $false)][object] $InputObject)

    $value = Get-FirstNestedPropertyValue -InputObject $InputObject -PropertyNames @(
        "createdon",
        "createdOn",
        "createdAt",
        "createdDate",
        "createdDateTime",
        "creationTime",
        "resource.createdon",
        "resource.createdOn",
        "metadata.createdon",
        "metadata.createdOn"
    ) -DefaultValue $null

    return ConvertTo-HarnessDateTime -Value $value
}

function Get-HarnessBotDetails {
    param(
        [Parameter(Mandatory = $false)][string] $DataverseUrl,
        [Parameter(Mandatory = $false)][string] $BotId
    )

    if ([string]::IsNullOrWhiteSpace($DataverseUrl) -or [string]::IsNullOrWhiteSpace($BotId)) {
        return $null
    }

    try {
        return Invoke-DataverseApi -Method GET -DataverseUrl $DataverseUrl -RelativePath "bots($BotId)?`$select=botid,name,template,createdon"
    }
    catch {
        $encodedFilter = [uri]::EscapeDataString("botid eq $BotId")
        $response = Invoke-DataverseApi -Method GET -DataverseUrl $DataverseUrl -RelativePath "bots?`$select=botid,name,template,createdon&`$filter=$encodedFilter&`$top=1"
        $matches = @(Get-PropertyValue -InputObject $response -PropertyName "value" -DefaultValue @())
        if ($matches.Count -gt 0) {
            return $matches[0]
        }
    }

    return $null
}

function Get-HarnessWorkflowDetails {
    param(
        [Parameter(Mandatory = $false)][string] $DataverseUrl,
        [Parameter(Mandatory = $false)][string] $ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($DataverseUrl) -or [string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    $escapedResourceId = $ResourceId.Replace("'", "''")
    $encodedFilter = [uri]::EscapeDataString("resourceid eq '$escapedResourceId'")
    $response = Invoke-DataverseApi -Method GET -DataverseUrl $DataverseUrl -RelativePath "workflows?`$select=workflowid,name,resourceid,createdon,modifiedon,description,clientdata,category,type,modernflowtype,statecode,statuscode,_ownerid_value&`$filter=$encodedFilter&`$top=1"
    $matches = @(Get-PropertyValue -InputObject $response -PropertyName "value" -DefaultValue @())
    if ($matches.Count -gt 0) {
        return $matches[0]
    }

    return $null
}

function Get-HarnessResourceMetadata {
    param([Parameter(Mandatory = $true)][object] $Row)

    $environmentUrl = Get-PropertyValue -InputObject $Row -PropertyName "EnvironmentDataverseUrl" -DefaultValue ""
    $resourceId = Get-PropertyValue -InputObject $Row -PropertyName "AgentId" -DefaultValue ""
    $resourceType = Get-PropertyValue -InputObject $Row -PropertyName "ResourceType" -DefaultValue ""
    $cacheKey = "$environmentUrl|$resourceType|$resourceId".ToLowerInvariant()

    if ($script:HarnessResourceMetadataCache.ContainsKey($cacheKey)) {
        return $script:HarnessResourceMetadataCache[$cacheKey]
    }

    $rawAgent = ConvertFrom-CompactJson -Value (Get-PropertyValue -InputObject $Row -PropertyName "RawAgentJson" -DefaultValue "")
    $createdOn = Get-FirstCreatedDateValue -InputObject $rawAgent
    $source = "BillableResource"
    $rowAgentName = Get-PropertyValue -InputObject $Row -PropertyName "AgentName" -DefaultValue ""
    $rowHarnessType = Get-PropertyValue -InputObject $Row -PropertyName "HarnessType" -DefaultValue ""
    $rowRawAgentJson = Get-PropertyValue -InputObject $Row -PropertyName "RawAgentJson" -DefaultValue ""
    $evidence = @($rowAgentName, $rowHarnessType, $rowRawAgentJson) -join " "

    if ($resourceType -eq "Agent") {
        try {
            $bot = Get-HarnessBotDetails -DataverseUrl $environmentUrl -BotId $resourceId
            if ($null -ne $bot) {
                $botCreatedOn = Get-FirstCreatedDateValue -InputObject $bot
                if ($null -ne $botCreatedOn) {
                    $createdOn = $botCreatedOn
                    $source = "DataverseBot"
                }

                $botName = Get-PropertyValue -InputObject $bot -PropertyName "name" -DefaultValue ""
                $botTemplate = Get-PropertyValue -InputObject $bot -PropertyName "template" -DefaultValue ""
                $evidence = "$evidence $botName $botTemplate"
            }
        }
        catch {
            Write-Warning "Could not read Dataverse bot details for '$resourceId': $($_.Exception.Message)"
        }
    }
    elseif ($resourceType -eq "Workflow") {
        try {
            $workflow = Get-HarnessWorkflowDetails -DataverseUrl $environmentUrl -ResourceId $resourceId
            if ($null -ne $workflow) {
                $workflowCreatedOn = Get-FirstCreatedDateValue -InputObject $workflow
                if ($null -ne $workflowCreatedOn) {
                    $createdOn = $workflowCreatedOn
                    $source = "DataverseWorkflow"
                }

                $workflowName = Get-PropertyValue -InputObject $workflow -PropertyName "name" -DefaultValue ""
                $workflowDescription = Get-PropertyValue -InputObject $workflow -PropertyName "description" -DefaultValue ""
                $workflowClientData = Get-PropertyValue -InputObject $workflow -PropertyName "clientdata" -DefaultValue ""
                $evidence = "$evidence $workflowName $workflowDescription $workflowClientData"
            }
        }
        catch {
            Write-Warning "Could not read Dataverse workflow details for '$resourceId': $($_.Exception.Message)"
        }
    }

    $harnessType = Get-PropertyValue -InputObject $Row -PropertyName "HarnessType" -DefaultValue ""
    $isGitHubHarnessAgent = ($resourceType -eq "Agent" -and $harnessType -eq "GitHub Copilot Harness")
    $isGitHubHarnessWorkflow = ($resourceType -eq "Workflow" -and $evidence -match $HarnessTextPattern)
    $isFallbackMatch = ($resourceType -eq "Agent" -and $evidence -match $HarnessTextPattern)

    $metadata = [pscustomobject]@{
        CreatedOn   = $createdOn
        Source      = $source
        IsMatch     = ($isGitHubHarnessAgent -or $isGitHubHarnessWorkflow -or $isFallbackMatch)
        MatchReason = if ($isGitHubHarnessAgent) {
            "Agent HarnessType = GitHub Copilot Harness"
        }
        elseif ($isGitHubHarnessWorkflow) {
            "Workflow matched GitHub Copilot harness pattern"
        }
        elseif ($isFallbackMatch) {
            "Agent matched GitHub Copilot harness pattern"
        }
        else {
            ""
        }
    }

    $script:HarnessResourceMetadataCache[$cacheKey] = $metadata
    return $metadata
}

function Set-HarnessDesiredLimitDefaults {
    param(
        [Parameter(Mandatory = $true)][object] $Row,
        [Parameter(Mandatory = $true)][int] $DesiredLimit,
        [Parameter(Mandatory = $false)][bool] $StopUsage = $true
    )

    $Row.DesiredMessageLimit = $DesiredLimit
    $Row.DesiredStopUsageAtLimit = $StopUsage

    if ((ConvertTo-Bool $Row.DesiredOverageNotificationEnabled $true)) {
        $threshold = [int](ConvertTo-Number $Row.DesiredNotificationThreshold)
        if ($threshold -lt 50 -or $threshold -gt 100) {
            $Row.DesiredNotificationThreshold = 80
        }
    }
}

function Set-HarnessThresholdExactProperty {
    param(
        [Parameter(Mandatory = $true)][object] $Target,
        [Parameter(Mandatory = $true)][string] $PropertyName,
        [Parameter(Mandatory = $true)][object] $Value
    )

    $Target | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $Value -Force
}

function Get-HarnessNestedPathValue {
    param(
        [Parameter(Mandatory = $false)][object] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $false)][object] $DefaultValue = $null
    )

    foreach ($path in $Paths) {
        $current = $InputObject
        $found = $true
        foreach ($part in $path.Split(".")) {
            if ($null -eq $current) {
                $found = $false
                break
            }

            $property = @($current.PSObject.Properties | Where-Object { $_.Name -eq $part } | Select-Object -First 1)
            if ($property.Count -eq 0) {
                $found = $false
                break
            }

            $current = $property[0].Value
        }

        if ($found -and $null -ne $current -and "$current" -ne "") {
            return $current
        }
    }

    return $DefaultValue
}

function Get-HarnessUsageValues {
    param([Parameter(Mandatory = $false)][object] $Resource)

    $billed = Get-ResourceCreditValue -Resource $Resource -PropertyNames @("consumed", "consumed.value", "entitlement.consumed.value", "payGo.consumed.value", "billedCredits", "billedCredit", "billedCopilotCredits", "billedCopilotCredit", "billedUsageCredits", "billedUsageCredit", "billedMessages", "billedMessageCount", "billedUnits", "billedUnitCount", "billedConsumption", "billableCredits", "billableCredit", "billableMessages", "billableMessageCount", "billableUnits", "billableConsumption", "chargedCredits", "chargedCredit", "chargedConsumption", "paidCredits", "paidCredit", "paidMessages", "paidConsumption", "meteredCredits", "meteredCredit", "meteredConsumption", "consumedQuantity") -IncludePattern "(?i)(billed|billable|charged|paid|metered|consumed).*(credit|usage|consumption|message|unit|quantity|count|value)" -ExcludePattern "(?i)(non|unbilled|free|included|available|limit|threshold)"
    $nonBilled = Get-ResourceCreditValue -Resource $Resource -PropertyNames @("metadata.NonBillableQuantity", "metadata.nonBillableQuantity", "nonBilledCredits", "nonBilledCredit", "nonBilledCopilotCredits", "nonBilledCopilotCredit", "nonBilledMessages", "nonBilledMessageCount", "nonBilledUnits", "nonBilledConsumption", "nonBillableCredits", "nonBillableCredit", "nonBillableMessages", "nonBillableMessageCount", "nonBillableUnits", "nonBillableConsumption", "nonBillableQuantity", "NonBillableQuantity", "nonbilledCredits", "nonbillableCredits", "unbilledCredits", "unbilledCredit", "unbilledMessages", "unbilledConsumption", "freeCredits", "freeCredit", "freeMessages", "freeConsumption", "includedCredits", "includedCredit", "includedMessages", "includedConsumption") -IncludePattern "(?i)(non.?billed|non.?billable|unbilled|free|included).*(credit|usage|consumption|message|unit|quantity|count)" -ExcludePattern "(?i)(available|limit|threshold)"
    $consumed = [double](ConvertTo-Number (Get-FirstNestedPropertyValue -InputObject $Resource -PropertyNames @("consumed", "consumed.value", "entitlement.consumed.value", "payGo.consumed.value", "consumedQuantity", "usage.value", "usage", "billedUsage", "messageCount", "currentUsage", "totalMessages", "totalMessageCount", "totalConsumption", "consumption.value", "consumption") -DefaultValue 0))
    $billedFromPath = ConvertTo-Number (Get-HarnessNestedPathValue -InputObject $Resource -Paths @("consumed", "consumed.value", "entitlement.consumed.value", "payGo.consumed.value", "capacity.consumed.value") -DefaultValue $null)
    $nonBilledFromPath = ConvertTo-Number (Get-HarnessNestedPathValue -InputObject $Resource -Paths @("metadata.NonBillableQuantity", "metadata.nonBillableQuantity") -DefaultValue $null)
    if ($billedFromPath -ne 0) {
        $billed = [double]$billedFromPath
        $consumed = [double]$billedFromPath
    }
    if ($nonBilledFromPath -ne 0) {
        $nonBilled = [double]$nonBilledFromPath
    }

    if ($consumed -eq 0 -and $billed -ne 0) {
        $consumed = $billed
    }

    [pscustomobject]@{
        Consumed  = [double]$consumed
        Billed    = [double]$billed
        NonBilled = [double]$nonBilled
    }
}

function Add-HarnessUsageMapResource {
    param(
        [Parameter(Mandatory = $true)][hashtable] $UsageByKey,
        [Parameter(Mandatory = $true)][object] $Resource
    )

    $environmentId = Get-FirstNestedPropertyValue -InputObject $Resource -PropertyNames @("environmentId", "environmentName", "environment") -DefaultValue ""
    $resourceId = Get-FirstNestedPropertyValue -InputObject $Resource -PropertyNames @("resourceId", "agentId", "botId", "id", "name") -DefaultValue ""
    $resourceName = Get-FirstNestedPropertyValue -InputObject $Resource -PropertyNames @("displayName", "resourceDisplayName", "resourceName", "ResourceName", "metadata.ResourceName", "agentName", "botName", "friendlyName", "title") -DefaultValue ""
    if ([string]::IsNullOrWhiteSpace($environmentId) -or [string]::IsNullOrWhiteSpace($resourceId)) {
        return
    }

    $values = Get-HarnessUsageValues -Resource $Resource
    if ($values.Consumed -eq 0 -and $values.Billed -eq 0 -and $values.NonBilled -eq 0) {
        return
    }

    $UsageByKey[(Get-ThresholdKey -EnvironmentId $environmentId -ResourceId $resourceId)] = $values
    if (-not [string]::IsNullOrWhiteSpace($resourceName)) {
        $UsageByKey["name|$($environmentId.ToLowerInvariant())|$($resourceName.ToLowerInvariant())"] = $values
    }
}

function Get-HarnessJwtPayload {
    param([Parameter(Mandatory = $true)][string] $Token)

    $payload = $Token.Split(".")[1].Replace("-", "+").Replace("_", "/")
    switch ($payload.Length % 4) {
        2 { $payload += "==" }
        3 { $payload += "=" }
    }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Get-HarnessCurrentUserObjectId {
    $token = Get-PowerPlatformAccessToken
    $payload = Get-HarnessJwtPayload -Token $token
    return [string]$payload.oid
}

function Add-HarnessUserAgentUsageOverlay {
    param(
        [Parameter(Mandatory = $true)][hashtable] $UsageByKey,
        [Parameter(Mandatory = $true)][object[]] $Rows,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd
    )

    $tenantHost = Get-TenantScopedApiHost
    if ([string]::IsNullOrWhiteSpace($tenantHost)) {
        return
    }

    $userObjectId = Get-HarnessCurrentUserObjectId
    if ([string]::IsNullOrWhiteSpace($userObjectId)) {
        return
    }

    $monthStart = (Get-Date -Year $WindowEnd.Year -Month $WindowEnd.Month -Day 1).Date
    $from = [uri]::EscapeDataString($monthStart.ToString("yyyy-MM-dd"))
    $to = [uri]::EscapeDataString($WindowEnd.Date.ToString("yyyy-MM-dd"))
    $searchTerms = @(
        $Rows | ForEach-Object {
            Get-PropertyValue -InputObject $_ -PropertyName "AgentName" -DefaultValue ""
            Get-PropertyValue -InputObject $_ -PropertyName "AgentId" -DefaultValue ""
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    )

    foreach ($searchTerm in $searchTerms) {
        try {
            $search = [uri]::EscapeDataString($searchTerm)
            $encodedUserObjectId = [uri]::EscapeDataString($userObjectId)
            $uri = "$tenantHost/licensing/entitlements/$EntitlementId/users/$encodedUserObjectId/resources?fromDate=$from&toDate=$to&pageSize=100&searchRequest=$search&api-version=1"
            Write-Host "Reading user agent usage for '$searchTerm'..."
            $response = Invoke-Api -Method GET -Uri $uri -Audience PowerPlatform
            foreach ($resource in @(Get-Collection $response)) {
                foreach ($nestedResource in @(Get-PropertyValue -InputObject $resource -PropertyName "resources" -DefaultValue @())) {
                    Add-HarnessUsageMapResource -UsageByKey $UsageByKey -Resource $nestedResource
                }

                Add-HarnessUsageMapResource -UsageByKey $UsageByKey -Resource $resource
            }
        }
        catch {
            Write-Warning "Could not load user-agent usage for '$searchTerm': $($_.Exception.Message)"
        }
    }
}

function Get-HarnessPvaGatewayByEnvironment {
    $pvaByEnvironment = @{}

    try {
        $bapUri = "$BapBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-06-01&`$expand=properties.runtimeEndpoints"
        $bapResponse = Invoke-Api -Method GET -Uri $bapUri -Audience Bap
        foreach ($environment in @(Get-Collection $bapResponse)) {
            $environmentId = Get-PropertyValue -InputObject $environment -PropertyName "name" -DefaultValue ""
            $properties = Get-PropertyValue -InputObject $environment -PropertyName "properties" -DefaultValue $null
            $runtimeEndpoints = Get-PropertyValue -InputObject $properties -PropertyName "runtimeEndpoints" -DefaultValue $null
            $pvaUrl = Get-FirstNestedPropertyValue -InputObject $runtimeEndpoints -PropertyNames @("microsoft.PowerVirtualAgents") -DefaultValue ""
            if (-not [string]::IsNullOrWhiteSpace($environmentId) -and -not [string]::IsNullOrWhiteSpace($pvaUrl)) {
                $pvaByEnvironment[$environmentId.ToLowerInvariant()] = $pvaUrl.TrimEnd("/")
            }
        }
    }
    catch {
        Write-Warning "Could not discover Power Virtual Agents gateway endpoints: $($_.Exception.Message)"
    }

    return $pvaByEnvironment
}

function Invoke-HarnessPvaGatewayRequest {
    param(
        [Parameter(Mandatory = $true)][string] $PvaGatewayUrl,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $gatewayUrl = $PvaGatewayUrl.TrimEnd("/")
    $token = Get-DataverseAccessToken -DataverseUrl $gatewayUrl
    $headers = @{
        Authorization = "Bearer $token"
        Accept        = "application/json"
    }
    $uri = "$gatewayUrl/$($RelativePath.TrimStart('/'))"
    return Invoke-RestMethodWithRetry -Method GET -Uri $uri -Headers $headers
}

function Get-HarnessPvaBillingUsage {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentId,
        [Parameter(Mandatory = $true)][string] $PvaGatewayUrl,
        [Parameter(Mandatory = $true)][string] $BotId,
        [Parameter(Mandatory = $true)][datetime] $WindowStart,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd,
        [Parameter(Mandatory = $false)][string] $CreatedOn = ""
    )

    $startUtc = $WindowStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
    $endUtc = $WindowEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
    $botCreateDate = if ([string]::IsNullOrWhiteSpace($CreatedOn)) { $startUtc } else { $CreatedOn }

    $encodedStart = [uri]::EscapeDataString($startUtc.Replace("Z", ".000Z"))
    $encodedEnd = [uri]::EscapeDataString($endUtc.Replace("Z", ".000Z"))
    $encodedCreate = [uri]::EscapeDataString($botCreateDate)
    $encodedEnvironmentId = [uri]::EscapeDataString($EnvironmentId)
    $encodedBotId = [uri]::EscapeDataString($BotId)
    $relativePath = "api/botmanagement/v1/environments/$encodedEnvironmentId/bots/$encodedBotId/analytics/billing/summary?utcStartTime=$encodedStart&utcEndTime=$encodedEnd&botCreateDate=$encodedCreate"
    $summary = Invoke-HarnessPvaGatewayRequest -PvaGatewayUrl $PvaGatewayUrl -RelativePath $relativePath
    $messages = Get-PropertyValue -InputObject $summary -PropertyName "messages" -DefaultValue $null
    $total = [double](ConvertTo-Number (Get-FirstNestedPropertyValue -InputObject $messages -PropertyNames @("total.value") -DefaultValue 0))
    $usage = [double](ConvertTo-Number (Get-FirstNestedPropertyValue -InputObject $messages -PropertyNames @("limitDetails.usage.value") -DefaultValue 0))

    if ($usage -eq 0 -and $total -ne 0) {
        $usage = $total
    }

    return [pscustomobject]@{
        Consumed  = $usage
        Billed    = $total
        NonBilled = 0.0
    }
}

function Update-HarnessRowsWithPvaBillingUsage {
    param(
        [Parameter(Mandatory = $true)][object[]] $Rows,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd
    )

    $agentRows = @($Rows | Where-Object {
        (Get-PropertyValue -InputObject $_ -PropertyName "ResourceType" -DefaultValue "") -eq "Agent" -and
        [double](ConvertTo-Number (Get-PropertyValue -InputObject $_ -PropertyName "BilledCopilotCredits" -DefaultValue 0)) -eq 0
    })
    if ($agentRows.Count -eq 0) {
        return
    }

    $pvaByEnvironment = Get-HarnessPvaGatewayByEnvironment
    $monthStart = (Get-Date -Year $WindowEnd.Year -Month $WindowEnd.Month -Day 1).Date

    foreach ($row in $agentRows) {
        $environmentId = Get-PropertyValue -InputObject $row -PropertyName "EnvironmentId" -DefaultValue ""
        $botId = Get-PropertyValue -InputObject $row -PropertyName "AgentId" -DefaultValue ""
        if ([string]::IsNullOrWhiteSpace($environmentId) -or [string]::IsNullOrWhiteSpace($botId)) {
            continue
        }

        $environmentKey = $environmentId.ToLowerInvariant()
        if (-not $pvaByEnvironment.ContainsKey($environmentKey)) {
            continue
        }

        try {
            $createdOn = Get-PropertyValue -InputObject $row -PropertyName "CreatedOn" -DefaultValue ""
            $usage = Get-HarnessPvaBillingUsage -EnvironmentId $environmentId -PvaGatewayUrl $pvaByEnvironment[$environmentKey] -BotId $botId -WindowStart $monthStart -WindowEnd $WindowEnd -CreatedOn $createdOn
            if ($usage.Consumed -eq 0 -and $usage.Billed -eq 0 -and $usage.NonBilled -eq 0) {
                continue
            }

            $row.CurrentConsumedMessages = [double]$usage.Consumed
            $row.BilledCopilotCredits = [double]$usage.Billed
            $row.NonBilledCopilotCredits = [double]$usage.NonBilled
            $row.Status = Get-ResourceStatusValue -Consumed $usage.Consumed -Limit $row.CurrentMessageLimit -NotificationThresholdPercent $row.CurrentNotificationThreshold
        }
        catch {
            Write-Warning "Could not load PVA billing summary for '$($row.AgentName)' [$botId]: $($_.Exception.Message)"
        }
    }
}

function Update-HarnessRowsWithMonthToDateUsage {
    param(
        [Parameter(Mandatory = $true)][object[]] $Rows,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd
    )

    if ($Rows.Count -eq 0) {
        return
    }

    $oldFromDate = $script:QueryFromDate
    $oldToDate = $script:QueryToDate
    $usageByKey = @{}

    try {
        $monthStart = (Get-Date -Year $WindowEnd.Year -Month $WindowEnd.Month -Day 1).Date
        $script:QueryFromDate = $monthStart
        $script:QueryToDate = $WindowEnd.Date

        Add-HarnessUserAgentUsageOverlay -UsageByKey $usageByKey -Rows $Rows -WindowEnd $WindowEnd

    }
    finally {
        $script:QueryFromDate = $oldFromDate
        $script:QueryToDate = $oldToDate
    }

    foreach ($row in $Rows) {
        $environmentId = Get-PropertyValue -InputObject $row -PropertyName "EnvironmentId" -DefaultValue ""
        $resourceId = Get-PropertyValue -InputObject $row -PropertyName "AgentId" -DefaultValue ""
        $resourceName = Get-PropertyValue -InputObject $row -PropertyName "AgentName" -DefaultValue ""
        if ([string]::IsNullOrWhiteSpace($environmentId) -or [string]::IsNullOrWhiteSpace($resourceId)) {
            continue
        }

        $key = Get-ThresholdKey -EnvironmentId $environmentId -ResourceId $resourceId
        $nameKey = "name|$($environmentId.ToLowerInvariant())|$($resourceName.ToLowerInvariant())"
        if ($usageByKey.ContainsKey($key)) {
            $usage = $usageByKey[$key]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($resourceName) -and $usageByKey.ContainsKey($nameKey)) {
            $usage = $usageByKey[$nameKey]
        }
        else {
            continue
        }
        $row.CurrentConsumedMessages = [double]$usage.Consumed
        $row.BilledCopilotCredits = [double]$usage.Billed
        $row.NonBilledCopilotCredits = [double]$usage.NonBilled
        $row.Status = Get-ResourceStatusValue -Consumed $usage.Consumed -Limit $row.CurrentMessageLimit -NotificationThresholdPercent $row.CurrentNotificationThreshold
    }

    if ($EnablePvaBillingFallback) {
        Update-HarnessRowsWithPvaBillingUsage -Rows $Rows -WindowEnd $WindowEnd
    }
}

function Get-GitHubCopilotHarnessLimitRows {
    param(
        [Parameter(Mandatory = $true)][datetime] $WindowStart,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd,
        [Parameter(Mandatory = $true)][int] $DesiredLimit,
        [Parameter(Mandatory = $false)][bool] $StopUsage = $true,
        [Parameter(Mandatory = $false)][string] $TargetEnvironmentId = ""
    )

    $script:QueryFromDate = $WindowStart.Date
    $script:QueryToDate = $WindowEnd.Date
    $oldSkipUserAgentUsageLookup = $script:SkipUserAgentUsageLookup
    try {
        $script:SkipUserAgentUsageLookup = $true
        $rows = @(Get-CopilotAgentLimitRows)
    }
    finally {
        $script:SkipUserAgentUsageLookup = $oldSkipUserAgentUsageLookup
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetEnvironmentId)) {
        $rows = @($rows | Where-Object { (Get-PropertyValue -InputObject $_ -PropertyName "EnvironmentId" -DefaultValue "") -eq $TargetEnvironmentId })
    }

    $matchedRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $resourceType = Get-PropertyValue -InputObject $row -PropertyName "ResourceType" -DefaultValue ""
        if ($resourceType -notin @("Agent", "Workflow")) {
            continue
        }

        $metadata = Get-HarnessResourceMetadata -Row $row
        if (-not $metadata.IsMatch -or $null -eq $metadata.CreatedOn) {
            continue
        }

        if ($metadata.CreatedOn -lt $WindowStart -or $metadata.CreatedOn -gt $WindowEnd) {
            continue
        }

        $row | Add-Member -NotePropertyName "CreatedOn" -NotePropertyValue $metadata.CreatedOn.ToString("o") -Force
        $row | Add-Member -NotePropertyName "CreatedOnSource" -NotePropertyValue $metadata.Source -Force
        $row | Add-Member -NotePropertyName "MatchReason" -NotePropertyValue $metadata.MatchReason -Force
        Set-HarnessDesiredLimitDefaults -Row $row -DesiredLimit $DesiredLimit -StopUsage $StopUsage
        [void] $matchedRows.Add($row)
    }

    $knownKeys = @{}
    foreach ($row in $matchedRows) {
        $keyEnvironmentId = Get-PropertyValue -InputObject $row -PropertyName "EnvironmentId" -DefaultValue ""
        $keyResourceId = Get-PropertyValue -InputObject $row -PropertyName "AgentId" -DefaultValue ""
        if (-not [string]::IsNullOrWhiteSpace($keyEnvironmentId) -and -not [string]::IsNullOrWhiteSpace($keyResourceId)) {
            $knownKeys[(Get-ThresholdKey -EnvironmentId $keyEnvironmentId -ResourceId $keyResourceId)] = $true
        }
    }

    foreach ($workflowRow in @(Get-GitHubCopilotHarnessWorkflowRowsFromDataverse -WindowStart $WindowStart -WindowEnd $WindowEnd -DesiredLimit $DesiredLimit -StopUsage $StopUsage -KnownKeys $knownKeys -TargetEnvironmentId $TargetEnvironmentId)) {
        [void] $matchedRows.Add($workflowRow)
    }

    Update-HarnessRowsWithMonthToDateUsage -Rows @($matchedRows) -WindowEnd $WindowEnd

    return @($matchedRows | Sort-Object CreatedOn, EnvironmentName, ResourceType, AgentName)
}

function Get-GitHubCopilotHarnessWorkflowRowsFromDataverse {
    param(
        [Parameter(Mandatory = $true)][datetime] $WindowStart,
        [Parameter(Mandatory = $true)][datetime] $WindowEnd,
        [Parameter(Mandatory = $true)][int] $DesiredLimit,
        [Parameter(Mandatory = $false)][bool] $StopUsage = $true,
        [Parameter(Mandatory = $true)][hashtable] $KnownKeys,
        [Parameter(Mandatory = $false)][string] $TargetEnvironmentId = ""
    )

    $environments = @(Get-EnvironmentList | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.DataverseUrl) -and
        ([string]::IsNullOrWhiteSpace($TargetEnvironmentId) -or $_.EnvironmentId -eq $TargetEnvironmentId)
    })
    $thresholds = @(Get-AgentThresholds)
    $thresholdByKey = @{}
    foreach ($threshold in $thresholds) {
        $thresholdEnvironmentId = Get-FirstPropertyValue -InputObject $threshold -PropertyNames @("environmentId", "environmentName", "environment") -DefaultValue ""
        $thresholdResourceId = Get-FirstPropertyValue -InputObject $threshold -PropertyNames @("resourceId", "agentId", "botId", "id") -DefaultValue ""
        if (-not [string]::IsNullOrWhiteSpace($thresholdEnvironmentId) -and -not [string]::IsNullOrWhiteSpace($thresholdResourceId)) {
            $thresholdByKey[(Get-ThresholdKey -EnvironmentId $thresholdEnvironmentId -ResourceId $thresholdResourceId)] = $threshold
        }
    }

    $startUtc = $WindowStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
    $endUtc = $WindowEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)

    foreach ($environment in $environments) {
        Write-Host "Reading Dataverse workflows for environment $($environment.EnvironmentId)..."
        $filter = [uri]::EscapeDataString("category eq 5 and type eq 1 and modernflowtype eq 1 and (statecode eq 0 or statecode eq 1)")
        $relativePath = "workflows?`$select=workflowid,name,modifiedon,createdon,statecode,statuscode,resourceid,category,type,modernflowtype,_ownerid_value,clientdata&`$filter=$filter&`$orderby=modifiedon desc&`$top=5000"
        $workflows = @()

        try {
            $workflows = @(Get-DataversePagedCollection -DataverseUrl $environment.DataverseUrl -RelativePath $relativePath)
        }
        catch {
            Write-Warning "Could not read Dataverse workflows from '$($environment.DataverseUrl)': $($_.Exception.Message)"
            continue
        }

        foreach ($workflow in $workflows) {
            $workflowName = Get-PropertyValue -InputObject $workflow -PropertyName "name" -DefaultValue ""

            $resourceId = Get-PropertyValue -InputObject $workflow -PropertyName "resourceid" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace($resourceId)) {
                $resourceId = Get-PropertyValue -InputObject $workflow -PropertyName "workflowid" -DefaultValue ""
            }

            if ([string]::IsNullOrWhiteSpace($resourceId)) {
                Write-Warning "Skipping workflow '$workflowName' because it has no resourceid or workflowid."
                continue
            }

            $key = Get-ThresholdKey -EnvironmentId $environment.EnvironmentId -ResourceId $resourceId
            if ($KnownKeys.ContainsKey($key)) {
                continue
            }

            $threshold = $thresholdByKey[$key]
            $currentLimit = [int](ConvertTo-Number (Get-CurrentSetting -Threshold $threshold -Agent $workflow -PropertyNames @("maxMessageLimit", "messageLimit", "capacityLimit", "limit", "requestLimit") -DefaultValue 0))
            $stopUsage = ConvertTo-Bool (Get-CurrentSetting -Threshold $threshold -Agent $workflow -PropertyNames @("turnOffAgentAtLimit", "stopUsageAtLimit", "stopUsage", "stopAtLimitEnabled", "throttlingEnabled", "isBlockingEnabled", "enforceLimit", "denyEnabled") -DefaultValue $true) $true
            $notifyEnabled = ConvertTo-Bool (Get-CurrentSetting -Threshold $threshold -Agent $workflow -PropertyNames @("overageNotificationEnabled", "notificationEnabled", "emailNotificationEnabled", "notifyEnabled", "alertEnabled") -DefaultValue $true) $true
            $notifyThreshold = [int](ConvertTo-Number (Get-CurrentSetting -Threshold $threshold -Agent $workflow -PropertyNames @("notificationThreshold", "overageNotificationThreshold", "thresholdPercentage", "alertThreshold", "threshold") -DefaultValue 80))
            $createdOn = ConvertTo-HarnessDateTime -Value (Get-PropertyValue -InputObject $workflow -PropertyName "createdon" -DefaultValue $null)
            if ($null -eq $createdOn -or $createdOn -lt $WindowStart -or $createdOn -gt $WindowEnd) {
                continue
            }

            $workflowRow = [pscustomobject]@{
                TenantId                            = $script:TenantId
                EntitlementId                       = $EntitlementId
                EnvironmentId                       = $environment.EnvironmentId
                EnvironmentName                     = $environment.EnvironmentName
                EnvironmentType                     = $environment.EnvironmentType
                EnvironmentDataverseUrl             = $environment.DataverseUrl
                Region                              = $environment.Region
                ResourceType                        = "Workflow"
                AgentId                             = $resourceId
                AgentName                           = $workflowName
                HarnessType                         = ""
                AgentState                          = "Unavailable"
                DesiredAgentState                   = "Unavailable"
                Status                              = Get-ResourceStatusValue -Consumed 0 -Limit $currentLimit -NotificationThresholdPercent $notifyThreshold
                CurrentConsumedMessages             = 0
                BilledCopilotCredits                = 0
                NonBilledCopilotCredits             = 0
                DrawFromTenantPool                  = $false
                TenantAvailableCopilotCredits       = 0
                EnvironmentAvailableCopilotCredits  = 0
                AvailableCopilotCredits             = 0
                CurrentMessageLimit                 = $currentLimit
                DesiredMessageLimit                 = $DesiredLimit
                CurrentStopUsageAtLimit             = $stopUsage
                DesiredStopUsageAtLimit             = $true
                CurrentOverageNotificationEnabled   = $notifyEnabled
                DesiredOverageNotificationEnabled   = $notifyEnabled
                CurrentNotificationThreshold        = $notifyThreshold
                DesiredNotificationThreshold        = $notifyThreshold
                ThresholdRecord                     = if ($threshold) { "Yes" } else { "No" }
                RawAgentJson                        = ConvertTo-CompactJson $workflow
                RawThresholdJson                    = ConvertTo-CompactJson $threshold
                CreatedOn                           = if ($createdOn) { $createdOn.ToString("o") } else { "" }
                CreatedOnSource                     = "DataverseWorkflow"
                MatchReason                         = "Copilot Studio workflows page query: category=5, type=1, modernflowtype=1"
            }

            Set-HarnessDesiredLimitDefaults -Row $workflowRow -DesiredLimit $DesiredLimit -StopUsage $StopUsage
            $workflowRow
        }
    }
}

function New-HarnessLimitDataTable {
    param([Parameter(Mandatory = $true)][object[]] $Rows)

    $table = New-CopilotAgentLimitDataTable -Rows $Rows
    if (-not $table.Columns.Contains("CreatedOn")) {
        [void] $table.Columns.Add("CreatedOn", [string])
    }
    if (-not $table.Columns.Contains("CreatedOnSource")) {
        [void] $table.Columns.Add("CreatedOnSource", [string])
    }
    if (-not $table.Columns.Contains("MatchReason")) {
        [void] $table.Columns.Add("MatchReason", [string])
    }

    for ($index = 0; $index -lt $Rows.Count; $index++) {
        $table.Rows[$index]["CreatedOn"] = Get-PropertyValue -InputObject $Rows[$index] -PropertyName "CreatedOn" -DefaultValue ""
        $table.Rows[$index]["CreatedOnSource"] = Get-PropertyValue -InputObject $Rows[$index] -PropertyName "CreatedOnSource" -DefaultValue ""
        $table.Rows[$index]["MatchReason"] = Get-PropertyValue -InputObject $Rows[$index] -PropertyName "MatchReason" -DefaultValue ""
    }

    return ,$table
}

function Export-HarnessGridCsv {
    param(
        [Parameter(Mandatory = $true)][System.Data.DataTable] $Table,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $rows = foreach ($dataRow in $Table.Rows) {
        $object = [ordered]@{}
        foreach ($column in $Table.Columns) {
            $object[$column.ColumnName] = $dataRow[$column.ColumnName]
        }

        [pscustomobject]$object
    }

    @($rows) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Get-HarnessEncodedPathSegment {
    param([Parameter(Mandatory = $true)][string] $Value)

    return [uri]::EscapeDataString($Value)
}

function New-HarnessThresholdBody {
    param([Parameter(Mandatory = $true)][object] $Row)

    $body = ConvertFrom-CompactJson -Value $Row.RawThresholdJson
    $environmentId = [string]$Row.EnvironmentId
    $resourceId = [string]$Row.AgentId
    $rowEntitlementId = if ([string]::IsNullOrWhiteSpace($Row.EntitlementId)) { $EntitlementId } else { [string]$Row.EntitlementId }
    $messageLimit = [int]$Row.DesiredMessageLimit
    $stopUsage = [bool]$Row.DesiredStopUsageAtLimit
    $notifyEnabled = [bool]$Row.DesiredOverageNotificationEnabled
    $notifyThreshold = [int]$Row.DesiredNotificationThreshold

    Set-ThresholdProperty -Target $body -DefaultPropertyName "environmentId" -CandidatePropertyNames @("environmentId") -Value $environmentId
    Set-ThresholdProperty -Target $body -DefaultPropertyName "entitlementId" -CandidatePropertyNames @("entitlementId") -Value $rowEntitlementId
    Set-ThresholdProperty -Target $body -DefaultPropertyName "resourceId" -CandidatePropertyNames @("resourceId", "agentId", "botId", "id") -Value $resourceId
    Set-ThresholdProperty -Target $body -DefaultPropertyName "maxMessageLimit" -CandidatePropertyNames @("maxMessageLimit", "messageLimit", "capacityLimit", "limit", "requestLimit") -Value $messageLimit
    Set-ThresholdProperty -Target $body -DefaultPropertyName "turnOffAgentAtLimit" -CandidatePropertyNames @("turnOffAgentAtLimit", "stopUsageAtLimit", "stopUsage", "stopAtLimitEnabled", "throttlingEnabled", "isBlockingEnabled", "enforceLimit", "denyEnabled") -Value $stopUsage
    Set-ThresholdProperty -Target $body -DefaultPropertyName "overageNotificationEnabled" -CandidatePropertyNames @("overageNotificationEnabled", "notificationEnabled", "emailNotificationEnabled", "notifyEnabled", "alertEnabled") -Value $notifyEnabled
    Set-ThresholdProperty -Target $body -DefaultPropertyName "notificationThreshold" -CandidatePropertyNames @("notificationThreshold", "overageNotificationThreshold", "thresholdPercentage", "alertThreshold", "threshold") -Value $notifyThreshold
    Set-HarnessThresholdExactProperty -Target $body -PropertyName "limit" -Value $messageLimit
    Set-HarnessThresholdExactProperty -Target $body -PropertyName "stopResource" -Value $stopUsage
    Set-HarnessThresholdExactProperty -Target $body -PropertyName "stopIfOverCapacity" -Value $stopUsage
    Set-HarnessThresholdExactProperty -Target $body -PropertyName "notifyIfOverCapacity" -Value $notifyEnabled

    return $body
}

function Invoke-HarnessThresholdWrite {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentId,
        [Parameter(Mandatory = $true)][string] $RowEntitlementId,
        [Parameter(Mandatory = $true)][string] $ResourceId,
        [Parameter(Mandatory = $true)][object] $Body,
        [Parameter(Mandatory = $true)][ValidateSet("Licensing", "PowerPlatform")][string] $Endpoint
    )

    $encodedEnvironmentId = Get-HarnessEncodedPathSegment -Value $EnvironmentId
    $encodedEntitlementId = Get-HarnessEncodedPathSegment -Value $RowEntitlementId
    $encodedResourceId = Get-HarnessEncodedPathSegment -Value $ResourceId

    if ($Endpoint -eq "Licensing") {
        $uri = "$LicensingBaseUrl/$LicensingDefaultApiVersion/tenants/$script:TenantId/environments/$encodedEnvironmentId/entitlements/$encodedEntitlementId/resources/$encodedResourceId/threshold"
        return Invoke-Api -Method PUT -Uri $uri -Audience Licensing -Body $Body
    }

    $uri = "$ApiBaseUrl/licensing/environments/$encodedEnvironmentId/entitlements/$encodedEntitlementId/resources/$encodedResourceId/threshold?api-version=1"
    return Invoke-Api -Method PUT -Uri $uri -Audience PowerPlatform -Body $Body
}

function Get-HarnessThresholdForResource {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentId,
        [Parameter(Mandatory = $true)][string] $ResourceId
    )

    $targetKey = Get-ThresholdKey -EnvironmentId $EnvironmentId -ResourceId $ResourceId
    foreach ($threshold in @(Get-AgentThresholds)) {
        $thresholdEnvironmentId = Get-FirstPropertyValue -InputObject $threshold -PropertyNames @("environmentId", "environmentName", "environment") -DefaultValue ""
        $thresholdResourceId = Get-FirstPropertyValue -InputObject $threshold -PropertyNames @("resourceId", "agentId", "botId", "id") -DefaultValue ""
        if ([string]::IsNullOrWhiteSpace($thresholdEnvironmentId) -or [string]::IsNullOrWhiteSpace($thresholdResourceId)) {
            continue
        }

        if ((Get-ThresholdKey -EnvironmentId $thresholdEnvironmentId -ResourceId $thresholdResourceId) -eq $targetKey) {
            return $threshold
        }
    }

    return $null
}

function Test-HarnessLimitPersisted {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentId,
        [Parameter(Mandatory = $true)][string] $ResourceId,
        [Parameter(Mandatory = $true)][int] $ExpectedLimit,
        [Parameter(Mandatory = $true)][scriptblock] $ProgressCallback
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if ($attempt -gt 1) {
            Start-Sleep -Seconds 3
        }

        $threshold = Get-HarnessThresholdForResource -EnvironmentId $EnvironmentId -ResourceId $ResourceId
        if ($null -eq $threshold) {
            & $ProgressCallback "Verification attempt ${attempt}: no threshold row returned yet for [$ResourceId]."
            continue
        }

        $actualLimit = [int](ConvertTo-Number (Get-CurrentSetting -Threshold $threshold -Agent $null -PropertyNames @("maxMessageLimit", "messageLimit", "capacityLimit", "limit", "requestLimit") -DefaultValue -1))
        if ($actualLimit -eq $ExpectedLimit) {
            return $true
        }

        & $ProgressCallback "Verification attempt ${attempt}: backend limit is $actualLimit, expected $ExpectedLimit for [$ResourceId]."
    }

    return $false
}

function Set-HarnessLimitRows {
    param(
        [Parameter(Mandatory = $true)][object[]] $Rows,
        [Parameter(Mandatory = $true)][scriptblock] $ProgressCallback
    )

    Test-GridRows -Rows $Rows
    Ensure-AzContext | Out-Null

    $updatedCount = 0
    $index = 0
    foreach ($row in $Rows) {
        $index++
        $agentName = [string]$row.AgentName
        $environmentId = [string]$row.EnvironmentId
        $resourceId = [string]$row.AgentId
        $rowEntitlementId = if ([string]::IsNullOrWhiteSpace($row.EntitlementId)) { $EntitlementId } else { [string]$row.EntitlementId }
        $messageLimit = [int]$row.DesiredMessageLimit
        $body = New-HarnessThresholdBody -Row $row

        & $ProgressCallback "Updating ($index/$($Rows.Count)): $agentName [$resourceId]"

        if (-not (Test-ThresholdSettingsChanged -Row $row)) {
            & $ProgressCallback "Skipped $agentName [$resourceId]; desired values already match current values."
            continue
        }

        $writeErrors = [System.Collections.Generic.List[string]]::new()
        foreach ($endpoint in @("Licensing", "PowerPlatform")) {
            try {
                Invoke-HarnessThresholdWrite -EnvironmentId $environmentId -RowEntitlementId $rowEntitlementId -ResourceId $resourceId -Body $body -Endpoint $endpoint | Out-Null
                & $ProgressCallback "Submitted $endpoint update for $agentName [$resourceId]. Verifying..."

                if (Test-HarnessLimitPersisted -EnvironmentId $environmentId -ResourceId $resourceId -ExpectedLimit $messageLimit -ProgressCallback $ProgressCallback) {
                    $updatedCount++
                    & $ProgressCallback "Verified $agentName [$resourceId] limit is now $messageLimit."
                    break
                }

                [void] $writeErrors.Add("$endpoint endpoint accepted the update but verification did not show limit $messageLimit.")
            }
            catch {
                [void] $writeErrors.Add("$endpoint endpoint failed: $($_.Exception.Message)")
            }
        }

        if ($writeErrors.Count -gt 0 -and $updatedCount -lt $index) {
            throw "Limit update was not verified for '$agentName' [$resourceId] in environment '$environmentId'. $($writeErrors -join ' ')"
        }
    }

    return $updatedCount
}

function Invoke-HarnessLimitSet {
    param(
        [Parameter(Mandatory = $true)][System.Data.DataTable] $Table,
        [Parameter(Mandatory = $true)][scriptblock] $ProgressCallback
    )

    $rows = @(Get-GridRows -Table $Table)
    $changedRows = @($rows | Where-Object { Test-GridRowChanged -Row $_ })
    if ($changedRows.Count -eq 0) {
        & $ProgressCallback "No changed rows found. Nothing to update."
        return 0
    }

    if ($PSCmdlet.ShouldProcess("$($changedRows.Count) GitHub Copilot harness resource(s)", "Set message limit")) {
        return (Set-HarnessLimitRows -Rows $changedRows -ProgressCallback $ProgressCallback)
    }

    return 0
}

function Invoke-HarnessScheduledJobRun {
    Ensure-RequiredModules

    Write-Host "Run mode: ScheduledJob"
    Write-Host "Range: $($resolvedRange.Start.ToString("yyyy-MM-dd")) through $($resolvedRange.End.ToString("yyyy-MM-dd"))"
    Write-Host "Limit value: $LimitValue"
    if ([string]::IsNullOrWhiteSpace($EnvironmentId)) {
        Write-Host "Environment: all environments"
    }
    else {
        Write-Host "Environment: $EnvironmentId"
    }

    $auditFolder = Split-Path -Path $AuditCsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($auditFolder)) {
        New-Item -Path $auditFolder -ItemType Directory -Force | Out-Null
    }

    $rows = @(Get-GitHubCopilotHarnessLimitRows -WindowStart $resolvedRange.Start -WindowEnd $resolvedRange.End -DesiredLimit $LimitValue -StopUsage $StopUsageAtLimit -TargetEnvironmentId $EnvironmentId)
    $table = New-HarnessLimitDataTable -Rows $rows
    Export-HarnessGridCsv -Table $table -Path $AuditCsvPath
    Write-Host "Exported $($rows.Count) matching GitHub Copilot harness resource(s) to: $AuditCsvPath"

    $updatedCount = Invoke-HarnessLimitSet -Table $table -ProgressCallback { param($m) Write-Host $m }
    Write-Host "Submitted limit updates for $updatedCount changed resource(s)."

    [pscustomobject]@{
        RunMode         = "ScheduledJob"
        RangeStart      = $resolvedRange.Start
        RangeEnd        = $resolvedRange.End
        LimitValue      = $LimitValue
        EnvironmentId   = $EnvironmentId
        MatchedCount    = $rows.Count
        UpdatedCount    = $updatedCount
        AuditCsvPath    = $AuditCsvPath
    }
}

function Show-GitHubCopilotHarnessLimitDashboard {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "GitHub Copilot Harness Resource Limit Dashboard"
    $form.Width = 1420
    $form.Height = 860
    $form.MinimumSize = New-Object System.Drawing.Size(1180, 760)
    $form.StartPosition = "CenterScreen"
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)

    $colorSurface = [System.Drawing.Color]::White
    $colorSoft = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $colorBorder = [System.Drawing.Color]::FromArgb(214, 221, 230)
    $colorText = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $colorMuted = [System.Drawing.Color]::FromArgb(93, 107, 123)
    $colorAccent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $colorAccentDark = [System.Drawing.Color]::FromArgb(0, 92, 160)
    $colorEditable = [System.Drawing.Color]::FromArgb(255, 252, 232)

    function Set-ButtonStyle {
        param(
            [System.Windows.Forms.Button] $Button,
            [bool] $Primary = $false
        )

        $Button.Height = 34
        $Button.FlatStyle = "Flat"
        $Button.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $Button.FlatAppearance.BorderSize = 1
        if ($Primary) {
            $Button.BackColor = $colorAccent
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $colorAccentDark
        }
        else {
            $Button.BackColor = $colorSurface
            $Button.ForeColor = $colorText
            $Button.FlatAppearance.BorderColor = $colorBorder
        }
    }

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Left = 16
    $headerPanel.Top = 12
    $headerPanel.Width = 1368
    $headerPanel.Height = 64
    $headerPanel.Anchor = "Top,Left,Right"
    $headerPanel.BackColor = $colorSurface
    $headerPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "GitHub Copilot Harness Resource Limit Dashboard"
    $titleLabel.Left = 18
    $titleLabel.Top = 10
    $titleLabel.AutoSize = $true
    $titleLabel.ForeColor = $colorText
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $headerPanel.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = "Find new GitHub Copilot harness agents and workflows, review usage, and apply day-one limits."
    $subtitleLabel.Left = 20
    $subtitleLabel.Top = 40
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.ForeColor = $colorMuted
    $headerPanel.Controls.Add($subtitleLabel)

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Left = 16
    $filterPanel.Top = 88
    $filterPanel.Width = 1368
    $filterPanel.Height = 90
    $filterPanel.Anchor = "Top,Left,Right"
    $filterPanel.BackColor = $colorSurface
    $filterPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($filterPanel)

    $rangeLabel = New-Object System.Windows.Forms.Label
    $rangeLabel.Text = "Range"
    $rangeLabel.Left = 28
    $rangeLabel.Top = 104
    $rangeLabel.AutoSize = $true
    $rangeLabel.ForeColor = $colorMuted
    $form.Controls.Add($rangeLabel)

    $rangeBox = New-Object System.Windows.Forms.ComboBox
    $rangeBox.Left = 86
    $rangeBox.Top = 99
    $rangeBox.Width = 130
    $rangeBox.DropDownStyle = "DropDownList"
    [void] $rangeBox.Items.AddRange(@("Today", "Last7Days", "Custom"))
    $rangeBox.SelectedItem = $Range
    $form.Controls.Add($rangeBox)

    $fromLabel = New-Object System.Windows.Forms.Label
    $fromLabel.Text = "From"
    $fromLabel.Left = 245
    $fromLabel.Top = 104
    $fromLabel.AutoSize = $true
    $fromLabel.ForeColor = $colorMuted
    $form.Controls.Add($fromLabel)

    $fromDate = New-Object System.Windows.Forms.DateTimePicker
    $fromDate.Left = 292
    $fromDate.Top = 99
    $fromDate.Width = 115
    $fromDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $fromDate.Value = $resolvedRange.Start.Date
    $form.Controls.Add($fromDate)

    $toLabel = New-Object System.Windows.Forms.Label
    $toLabel.Text = "To"
    $toLabel.Left = 432
    $toLabel.Top = 104
    $toLabel.AutoSize = $true
    $toLabel.ForeColor = $colorMuted
    $form.Controls.Add($toLabel)

    $toDate = New-Object System.Windows.Forms.DateTimePicker
    $toDate.Left = 462
    $toDate.Top = 99
    $toDate.Width = 115
    $toDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $toDate.Value = $resolvedRange.End.Date
    $form.Controls.Add($toDate)

    $limitLabel = New-Object System.Windows.Forms.Label
    $limitLabel.Text = "Limit"
    $limitLabel.Left = 610
    $limitLabel.Top = 104
    $limitLabel.AutoSize = $true
    $limitLabel.ForeColor = $colorMuted
    $form.Controls.Add($limitLabel)

    $limitBox = New-Object System.Windows.Forms.NumericUpDown
    $limitBox.Left = 650
    $limitBox.Top = 99
    $limitBox.Width = 100
    $limitBox.Minimum = 0
    $limitBox.Maximum = [decimal][int]::MaxValue
    $limitBox.Value = $LimitValue
    $form.Controls.Add($limitBox)

    $environmentLabel = New-Object System.Windows.Forms.Label
    $environmentLabel.Text = "Environment ID (optional)"
    $environmentLabel.Left = 780
    $environmentLabel.Top = 104
    $environmentLabel.AutoSize = $true
    $environmentLabel.ForeColor = $colorMuted
    $form.Controls.Add($environmentLabel)

    $environmentBox = New-Object System.Windows.Forms.TextBox
    $environmentBox.Left = 930
    $environmentBox.Top = 99
    $environmentBox.Width = 270
    $environmentBox.Text = $EnvironmentId
    $form.Controls.Add($environmentBox)

    $stopUsageCheck = New-Object System.Windows.Forms.CheckBox
    $stopUsageCheck.Text = "Stop usage at limit"
    $stopUsageCheck.Left = 1220
    $stopUsageCheck.Top = 102
    $stopUsageCheck.Width = 150
    $stopUsageCheck.Checked = $StopUsageAtLimit
    $stopUsageCheck.ForeColor = $colorText
    $form.Controls.Add($stopUsageCheck)

    $loadButton = New-Object System.Windows.Forms.Button
    $loadButton.Text = "Get matching resources"
    $loadButton.Left = 28
    $loadButton.Top = 136
    $loadButton.Width = 165
    Set-ButtonStyle -Button $loadButton -Primary $true
    $form.Controls.Add($loadButton)

    $setButton = New-Object System.Windows.Forms.Button
    $setButton.Text = "Set limit for loaded resources"
    $setButton.Left = 205
    $setButton.Top = 136
    $setButton.Width = 190
    $setButton.Enabled = $false
    Set-ButtonStyle -Button $setButton -Primary $true
    $form.Controls.Add($setButton)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = "Export CSV"
    $exportButton.Left = 407
    $exportButton.Top = 136
    $exportButton.Width = 100
    $exportButton.Enabled = $false
    Set-ButtonStyle -Button $exportButton
    $form.Controls.Add($exportButton)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Left = 530
    $summary.Top = 143
    $summary.Width = 830
    $summary.Height = 24
    $summary.Text = "Ready."
    $summary.ForeColor = $colorMuted
    $form.Controls.Add($summary)

    foreach ($control in @(
        $rangeLabel,
        $rangeBox,
        $fromLabel,
        $fromDate,
        $toLabel,
        $toDate,
        $limitLabel,
        $limitBox,
        $environmentLabel,
        $environmentBox,
        $stopUsageCheck,
        $loadButton,
        $setButton,
        $exportButton,
        $summary
    )) {
        $control.BringToFront()
    }
    $filterPanel.SendToBack()

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Left = 16
    $grid.Top = 194
    $grid.Width = 1368
    $grid.Height = 470
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = "DisplayedCells"
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $true
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.BackgroundColor = $colorSurface
    $grid.BorderStyle = "FixedSingle"
    $grid.GridColor = $colorBorder
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $colorText
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.SelectionBackColor = $colorAccent
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $colorSoft
    $grid.RowHeadersWidth = 28
    $form.Controls.Add($grid)

    $status = New-Object System.Windows.Forms.TextBox
    $status.Left = 16
    $status.Top = 680
    $status.Width = 1368
    $status.Height = 126
    $status.Multiline = $true
    $status.ReadOnly = $true
    $status.ScrollBars = "Vertical"
    $status.Font = New-Object System.Drawing.Font("Consolas", 9)
    $status.BackColor = $colorSurface
    $status.ForeColor = $colorText
    $status.BorderStyle = "FixedSingle"
    $status.Anchor = "Bottom,Left,Right"
    $form.Controls.Add($status)

    function Write-UiStatus {
        param([string] $Message)
        $status.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Message`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Update-DatePickerState {
        $isCustom = ([string]$rangeBox.SelectedItem -eq "Custom")
        $fromDate.Enabled = $isCustom
        $toDate.Enabled = $isCustom
    }

    function Set-HarnessGridData {
        param([System.Data.DataTable] $Table)

        $script:HarnessGridTable = $Table
        $grid.DataSource = $Table.DefaultView

        foreach ($column in $grid.Columns) {
            $column.ReadOnly = $true
        }

        foreach ($hiddenColumn in @("TenantId", "EntitlementId", "EnvironmentId", "EnvironmentDataverseUrl", "HarnessType", "AgentState", "DesiredAgentState", "CreatedOnSource", "MatchReason", "RawAgentJson", "RawThresholdJson", "OriginalDesiredMessageLimit", "OriginalDesiredStopUsageAtLimit", "OriginalDesiredOverageNotificationEnabled", "OriginalDesiredNotificationThreshold", "OriginalDesiredAgentState")) {
            if ($grid.Columns.Contains($hiddenColumn)) {
                $grid.Columns[$hiddenColumn].Visible = $false
            }
        }

        $setButton.Enabled = ($Table.Rows.Count -gt 0)
        $exportButton.Enabled = ($Table.Rows.Count -gt 0)
        $summary.Text = "Loaded $($Table.Rows.Count) matching GitHub Copilot harness resource(s). Desired limit: $([int]$limitBox.Value)."
    }

    $rangeBox.Add_SelectedIndexChanged({ Update-DatePickerState })
    Update-DatePickerState

    $loadButton.Add_Click({
        try {
            $loadButton.Enabled = $false
            $setButton.Enabled = $false
            $exportButton.Enabled = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            Write-UiStatus "Checking modules and signing in if needed..."
            Ensure-RequiredModules

            $selectedRange = [string]$rangeBox.SelectedItem
            $selectedDates = Resolve-HarnessDateRange -SelectedRange $selectedRange -CustomStartDate $fromDate.Value -CustomEndDate $toDate.Value
            $dateRangeText = "{0:yyyy-MM-dd} through {1:yyyy-MM-dd}" -f $selectedDates.Start, $selectedDates.End
            Write-UiStatus "Loading resources created from $dateRangeText..."

            $targetEnvironmentId = $environmentBox.Text.Trim()
            $rows = @(Get-GitHubCopilotHarnessLimitRows -WindowStart $selectedDates.Start -WindowEnd $selectedDates.End -DesiredLimit ([int]$limitBox.Value) -StopUsage ([bool]$stopUsageCheck.Checked) -TargetEnvironmentId $targetEnvironmentId)
            $table = New-HarnessLimitDataTable -Rows $rows
            Set-HarnessGridData -Table $table
            Write-UiStatus "Loaded $($rows.Count) matching resource(s)."
        }
        catch {
            Write-UiStatus "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Get matching resources failed", "OK", "Error") | Out-Null
        }
        finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $loadButton.Enabled = $true
        }
    })

    $setButton.Add_Click({
        try {
            if ($null -eq $script:HarnessGridTable -or $script:HarnessGridTable.Rows.Count -eq 0) {
                throw "No matching resources are loaded."
            }

            $answer = [System.Windows.Forms.MessageBox]::Show(
                "This will set the message limit to $([int]$limitBox.Value) for $($script:HarnessGridTable.Rows.Count) loaded GitHub Copilot harness resource(s). Continue?",
                "Confirm limit update",
                "YesNo",
                "Warning"
            )

            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-UiStatus "Set limit cancelled."
                return
            }

            foreach ($dataRow in $script:HarnessGridTable.Rows) {
                $dataRow["DesiredMessageLimit"] = [int]$limitBox.Value
                $dataRow["DesiredStopUsageAtLimit"] = [bool]$stopUsageCheck.Checked
                if ([bool]$dataRow["DesiredOverageNotificationEnabled"]) {
                    $threshold = [int]$dataRow["DesiredNotificationThreshold"]
                    if ($threshold -lt 50 -or $threshold -gt 100) {
                        $dataRow["DesiredNotificationThreshold"] = 80
                    }
                }
            }

            $setButton.Enabled = $false
            Write-UiStatus "Applying limit updates..."
            $updatedCount = Invoke-HarnessLimitSet -Table $script:HarnessGridTable -ProgressCallback { param($m) Write-UiStatus $m }
            Write-UiStatus "Set limit completed for $updatedCount changed resource(s)."
            [System.Windows.Forms.MessageBox]::Show("Set limit completed for $updatedCount changed resource(s).", "Complete", "OK", "Information") | Out-Null
        }
        catch {
            Write-UiStatus "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Set limit failed", "OK", "Error") | Out-Null
        }
        finally {
            $setButton.Enabled = ($null -ne $script:HarnessGridTable -and $script:HarnessGridTable.Rows.Count -gt 0)
        }
    })

    $exportButton.Add_Click({
        try {
            if ($null -eq $script:HarnessGridTable -or $script:HarnessGridTable.Rows.Count -eq 0) {
                throw "No matching resources are loaded."
            }

            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            $dialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
            $dialog.FileName = [IO.Path]::GetFileName($AuditCsvPath)
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Export-HarnessGridCsv -Table $script:HarnessGridTable -Path $dialog.FileName
                Write-UiStatus "Exported CSV: $($dialog.FileName)"
            }
        }
        catch {
            Write-UiStatus "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Export failed", "OK", "Error") | Out-Null
        }
    })

    Write-UiStatus "Ready. Leave Environment ID blank to load matching agents and workflows from all environments."
    [void] $form.ShowDialog()
}

if ($RunMode -eq "ScheduledJob") {
    Invoke-HarnessScheduledJobRun | Format-List
}
elseif ($AutoSet -or $NoDashboard) {
    Write-Warning "-AutoSet and -NoDashboard are retained for compatibility. Prefer -RunMode ScheduledJob for unattended scheduled runs."
    Ensure-RequiredModules
    $rows = @(Get-GitHubCopilotHarnessLimitRows -WindowStart $resolvedRange.Start -WindowEnd $resolvedRange.End -DesiredLimit $LimitValue -StopUsage $StopUsageAtLimit -TargetEnvironmentId $EnvironmentId)
    $table = New-HarnessLimitDataTable -Rows $rows
    Export-HarnessGridCsv -Table $table -Path $AuditCsvPath
    Write-Host "Exported $($rows.Count) matching GitHub Copilot harness resource(s) to: $AuditCsvPath"

    if ($AutoSet) {
        $updatedCount = Invoke-HarnessLimitSet -Table $table -ProgressCallback { param($m) Write-Host $m }
        Write-Host "Submitted limit updates for $updatedCount changed resource(s)."
    }
}
else {
    Show-GitHubCopilotHarnessLimitDashboard
}

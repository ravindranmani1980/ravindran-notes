<#
.SYNOPSIS
    Lists Azure resources (and optionally resource groups) that are missing required tags.

.DESCRIPTION
    Uses Azure Resource Graph to read every resource in every subscription you can see,
    and reports which of the -RequiredTags each one is missing or has with an empty
    value. Tag names are compared case-insensitively, as Azure does. Read-only.

    Use it to measure tagging before switching policies from Audit to Deny, and to
    give resource owners a to-do list.

.PARAMETER RequiredTags
    Tag names that every resource should have. Default: Owner, CostCenter, Environment.

.PARAMETER IncludeResourceGroups
    Also check resource groups.

.PARAMETER SubscriptionId
    Limit the check to these subscription IDs. Default: every subscription you can see.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzUntaggedResources.ps1

.EXAMPLE
    .\Get-AzUntaggedResources.ps1 -RequiredTags Owner, CostCenter, Environment, Application -IncludeResourceGroups
#>
[CmdletBinding()]
param(
    [string[]]$RequiredTags = @('Owner', 'CostCenter', 'Environment'),
    [switch]$IncludeResourceGroups,
    [string[]]$SubscriptionId,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzUntaggedResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Search-AzGraph -ErrorAction SilentlyContinue)) {
    throw 'Search-AzGraph not found. Run: Install-Module Az.ResourceGraph -Scope CurrentUser'
}
if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

function Invoke-GraphQuery {
    param([Parameter(Mandatory)][string]$Query)
    $results = New-Object System.Collections.Generic.List[object]
    $skipToken = $null
    do {
        $params = @{ Query = $Query; First = 1000 }
        if ($SubscriptionId) { $params.Subscription = $SubscriptionId } else { $params.UseTenantScope = $true }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $page = Search-AzGraph @params
        $rows = if ($page.PSObject.Properties['Data']) { $page.Data } else { $page }
        foreach ($r in $rows) { $results.Add($r) }
        $skipToken = $page.SkipToken
    } while ($skipToken)
    $results
}

$subNames = @{}
foreach ($s in Invoke-GraphQuery "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, name") {
    $subNames[$s.subscriptionId] = $s.name
}

Write-Host 'Reading resources...' -ForegroundColor Cyan
$items = New-Object System.Collections.Generic.List[object]
foreach ($r in Invoke-GraphQuery 'Resources | project id, name, type, resourceGroup, subscriptionId, location, tags') { $items.Add($r) }
if ($IncludeResourceGroups) {
    foreach ($r in Invoke-GraphQuery "ResourceContainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | project id, name, type, resourceGroup = name, subscriptionId, location, tags") { $items.Add($r) }
}

$report = foreach ($r in $items) {
    # Case-insensitive view of the resource's tags
    $tags = @{}
    if ($r.tags) { foreach ($p in $r.tags.PSObject.Properties) { $tags[$p.Name.ToLowerInvariant()] = [string]$p.Value } }
    $missing = @($RequiredTags | Where-Object { -not $tags.ContainsKey($_.ToLowerInvariant()) -or [string]::IsNullOrWhiteSpace($tags[$_.ToLowerInvariant()]) })
    if ($missing.Count -eq 0) { continue }
    [pscustomobject]@{
        Subscription  = $subNames[$r.subscriptionId]
        ResourceGroup = $r.resourceGroup
        Name          = $r.name
        Type          = $r.type
        MissingTags   = $missing -join ', '
        MissingCount  = $missing.Count
        ExistingTags  = ($tags.Keys | Sort-Object) -join ', '
        ResourceId    = $r.id
    }
}

$report | Sort-Object Subscription, ResourceGroup, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$total = $items.Count
$bad = @($report).Count
$pct = if ($total) { [math]::Round((($total - $bad) / $total) * 100, 1) } else { 100 }
Write-Host "Checked $total item(s). Fully tagged: $pct%. Missing at least one tag: $bad." -ForegroundColor Cyan
foreach ($t in $RequiredTags) {
    $n = @($report | Where-Object { ($_.MissingTags -split ', ') -contains $t }).Count
    Write-Host ("  {0,-15} missing on {1}" -f $t, $n)
}
Write-Host "Report: $OutputFile" -ForegroundColor Green

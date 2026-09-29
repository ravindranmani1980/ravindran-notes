<#
.SYNOPSIS
    Finds orphaned Azure resources that cost money or clutter: unattached disks, unused public IPs and more.

.DESCRIPTION
    Uses Azure Resource Graph to check every subscription you can see for:
    - Managed disks that aren't attached to any VM
    - Public IP addresses not associated with anything
    - Network interfaces not attached to a VM or private endpoint
    - Network security groups not associated with any subnet or NIC
    - Snapshots older than -SnapshotAgeDays
    - Empty resource groups

    Read-only: it doesn't delete anything. Review the list with the resource owners,
    then delete what's no longer needed.

.PARAMETER SubscriptionId
    Limit the check to these subscription IDs. Default: every subscription you can see.

.PARAMETER SnapshotAgeDays
    Report snapshots older than this many days. Default 90.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Find-AzOrphanedResources.ps1

.EXAMPLE
    .\Find-AzOrphanedResources.ps1 -SnapshotAgeDays 30 -OutputFile .\orphans.csv

.NOTES
    Requires Az.Accounts and Az.ResourceGraph, and Reader access. Some "orphans" are
    intentional (a disk kept after a VM was deleted, a reserved public IP): check the
    tags and ask the owner before deleting.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [ValidateRange(1, 3650)][int]$SnapshotAgeDays = 90,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzOrphanedResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

# Each check returns id, name, resourceGroup, subscriptionId, location, tags, detail
$checks = [ordered]@{
    'Unattached disk' = @"
Resources
| where type =~ 'microsoft.compute/disks'
| where tostring(properties.diskState) =~ 'Unattached'
| project id, name, resourceGroup, subscriptionId, location, tags,
    detail = strcat(tostring(sku.name), ', ', tostring(properties.diskSizeGB), ' GB, created ', format_datetime(todatetime(properties.timeCreated), 'yyyy-MM-dd'))
"@
    'Unused public IP' = @"
Resources
| where type =~ 'microsoft.network/publicipaddresses'
| where isnull(properties.ipConfiguration) and isnull(properties.natGateway)
| project id, name, resourceGroup, subscriptionId, location, tags,
    detail = strcat(tostring(sku.name), ' SKU, ', tostring(properties.publicIPAllocationMethod), ', ', tostring(properties.ipAddress))
"@
    'Detached network interface' = @"
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isnull(properties.virtualMachine) and isnull(properties.privateEndpoint) and isnull(properties.privateLinkService)
| project id, name, resourceGroup, subscriptionId, location, tags,
    detail = tostring(properties.ipConfigurations[0].properties.privateIPAddress)
"@
    'Unassociated NSG' = @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| where coalesce(array_length(properties.networkInterfaces), 0) == 0 and coalesce(array_length(properties.subnets), 0) == 0
| project id, name, resourceGroup, subscriptionId, location, tags, detail = ''
"@
    'Old snapshot' = @"
Resources
| where type =~ 'microsoft.compute/snapshots'
| extend created = todatetime(properties.timeCreated)
| where created < ago($($SnapshotAgeDays)d)
| project id, name, resourceGroup, subscriptionId, location, tags,
    detail = strcat(tostring(properties.diskSizeGB), ' GB, created ', format_datetime(created, 'yyyy-MM-dd'))
"@
    'Empty resource group' = @"
ResourceContainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| extend rgKey = tolower(strcat(subscriptionId, '/', name))
| join kind=leftouter (
    Resources
    | extend rgKey = tolower(strcat(subscriptionId, '/', resourceGroup))
    | summarize resourceCount = count() by rgKey
  ) on rgKey
| where isnull(resourceCount)
| project id, name, resourceGroup = name, subscriptionId, location, tags, detail = 'No resources'
"@
}

$report = New-Object System.Collections.Generic.List[object]
foreach ($check in $checks.GetEnumerator()) {
    Write-Host "Checking: $($check.Key)..." -ForegroundColor Cyan
    foreach ($r in Invoke-GraphQuery $check.Value) {
        $owner = if ($r.tags -and $r.tags.PSObject.Properties['Owner']) { $r.tags.Owner } else { '' }
        $report.Add([pscustomobject]@{
            Finding       = $check.Key
            Subscription  = $subNames[$r.subscriptionId]
            ResourceGroup = $r.resourceGroup
            Name          = $r.name
            Location      = $r.location
            Detail        = $r.detail
            Owner         = $owner
            ResourceId    = $r.id
        })
    }
}

$report | Sort-Object Finding, Subscription, ResourceGroup | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Finding | Select-Object @{n='Finding';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Findings: $($report.Count). Report: $OutputFile" -ForegroundColor Green

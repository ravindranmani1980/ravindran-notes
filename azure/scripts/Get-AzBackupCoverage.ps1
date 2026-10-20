<#
.SYNOPSIS
    Shows which Azure VMs are protected by Azure Backup, and which aren't.

.DESCRIPTION
    Uses Azure Resource Graph to list every VM in every subscription you can see, and
    matches it against the VMs protected in Recovery Services vaults. For protected VMs
    it shows the vault, the backup policy and the last backup status. Read-only.

    New VMs are the usual gap. Run this weekly, or use an Azure Policy that configures
    backup automatically for VMs with a given tag.

.PARAMETER SubscriptionId
    Limit the check to these subscription IDs. Default: every subscription you can see.

.PARAMETER UnprotectedOnly
    Only list VMs without backup.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzBackupCoverage.ps1

.EXAMPLE
    .\Get-AzBackupCoverage.ps1 -UnprotectedOnly

.NOTES
    Requires Az.Accounts and Az.ResourceGraph, and Reader access to the VMs and vaults.
    Covers Azure Backup in Recovery Services vaults (the standard VM backup).
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [switch]$UnprotectedOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzBackupCoverage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

Write-Host 'Reading VMs and backup items...' -ForegroundColor Cyan
$vms = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project id = tolower(id), name, resourceGroup, subscriptionId, location, tags
"@

$protected = @{}
$items = Invoke-GraphQuery @"
RecoveryServicesResources
| where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems'
| where tostring(properties.backupManagementType) =~ 'AzureIaasVM'
| project vmId       = tolower(coalesce(tostring(properties.sourceResourceId), tostring(properties.dataSourceInfo.resourceID))),
          vault      = tostring(split(id, '/')[8]),
          policy     = tostring(properties.policyName),
          lastStatus = tostring(properties.lastBackupStatus),
          lastBackup = tostring(properties.lastBackupTime),
          state      = tostring(properties.protectionState)
"@
foreach ($i in $items) { if ($i.vmId) { $protected[$i.vmId] = $i } }

$report = foreach ($vm in $vms) {
    $b = $protected[$vm.id]
    if ($UnprotectedOnly -and $b) { continue }
    $owner = if ($vm.tags -and $vm.tags.PSObject.Properties['Owner']) { $vm.tags.Owner } else { '' }
    [pscustomobject]@{
        Subscription    = $subNames[$vm.subscriptionId]
        ResourceGroup   = $vm.resourceGroup
        VM              = $vm.name
        Location        = $vm.location
        Protected       = [bool]$b
        Vault           = if ($b) { $b.vault } else { '' }
        Policy          = if ($b) { $b.policy } else { '' }
        ProtectionState = if ($b) { $b.state } else { '' }
        LastBackup      = if ($b) { $b.lastBackup } else { '' }
        LastStatus      = if ($b) { $b.lastStatus } else { '' }
        Owner           = $owner
    }
}

$report | Sort-Object Protected, Subscription, ResourceGroup, VM | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$all = @($vms).Count
if (-not $UnprotectedOnly) {
    $ok = @($report | Where-Object Protected).Count
    $pct = if ($all) { [math]::Round(($ok / $all) * 100, 1) } else { 100 }
    Write-Host "VMs: $all   Protected: $ok ($pct%)   Not protected: $($all - $ok)" -ForegroundColor Cyan
    $check = @($report | Where-Object { $_.Protected -and $_.LastStatus -and $_.LastStatus -notmatch 'Healthy|Completed|Succeeded' })
    if ($check.Count) { Write-Warning "$($check.Count) protected VM(s) have a last backup status that needs checking." }
}
else {
    Write-Host "VMs without backup: $(@($report).Count) of $all" -ForegroundColor Cyan
}
Write-Host "Report: $OutputFile" -ForegroundColor Green

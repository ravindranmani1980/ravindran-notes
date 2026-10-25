<#
.SYNOPSIS
    Collects Azure Backup evidence for GxP scope: vault protection, last backup per item, and restore tests.

.DESCRIPTION
    For each subscription with GxP scope (subscriptions or resource groups tagged GxP = Yes),
    reads every Recovery Services vault and writes one CSV with three kinds of row:
    - Vault: soft delete and immutability state, and how many restore jobs ran in the last
      -Days days. A vault with no restore in that window is flagged: a backup that has never
      been restored is not yet proven.
    - Item: each protected Azure VM, SQL Server in Azure VM database and Azure Files share
      whose source is in GxP scope, with last backup time and status. Items with no
      successful backup within -StaleHours are flagged.
    - Restore: each restore job in the window, with its status, duration and who started it.
      This is the list to attach to restore test records.

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER SubscriptionId
    Subscriptions to check. Default: every enabled subscription you can read.

.PARAMETER TagName
    Tag that marks GxP scope. Default GxP.

.PARAMETER TagValue
    Tag value that marks GxP scope. Default Yes.

.PARAMETER AllScopes
    Ignore the tag and treat every subscription checked as GxP scope.

.PARAMETER Days
    How far back to look for restore jobs. Default 90.

.PARAMETER StaleHours
    Flag items whose last successful backup is older than this. Default 26.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzGxPBackupEvidence.ps1

.EXAMPLE
    .\Get-AzGxPBackupEvidence.ps1 -Days 180 -StaleHours 30

.NOTES
    Requires Az.Accounts, Az.Resources and Az.RecoveryServices, and Backup Reader on the
    vaults. Only Recovery Services vaults are read; Backup vaults (Azure Disk, Blob, PostgreSQL
    backup) are not covered yet. Azure Backup keeps job history for a limited time, so export
    this report on a schedule if you need a longer record.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$TagName = 'GxP',
    [string]$TagValue = 'Yes',
    [switch]$AllScopes,
    [ValidateRange(1, 365)][int]$Days = 90,
    [ValidateRange(1, 720)][int]$StaleHours = 26,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzGxPBackupEvidence_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# Signed in:  $((Get-AzContext).Account.Id)"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

function Get-TagValue($Tags, [string]$Name) {
    if (-not $Tags) { return $null }
    foreach ($k in $Tags.Keys) { if ($k -eq $Name) { return $Tags[$k] } }
    return $null
}

function New-Row {
    param($Sub, $Vault, [string]$RecordType)
    [ordered]@{
        Subscription = $Sub.Name; Vault = $Vault.Name; VaultResourceGroup = $Vault.ResourceGroupName; RecordType = $RecordType
        Name = ''; WorkloadType = ''; SourceResourceId = ''; Status = ''; LastBackup = $null; RestoreStart = $null; RestoreEnd = $null
        DurationMinutes = $null; StartedBy = ''; SoftDelete = ''; Immutability = ''; RestoresInWindow = $null; Flags = ''
    }
}

$workloads = @(
    @{ Management = 'AzureVM';       Workload = 'AzureVM' }
    @{ Management = 'AzureWorkload'; Workload = 'MSSQL' }
    @{ Management = 'AzureStorage';  Workload = 'AzureFiles' }
)
$now = Get-Date
$from = $now.AddDays(-$Days)

$subs = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' })
if ($SubscriptionId) { $subs = @($subs | Where-Object { $SubscriptionId -contains $_.Id }) }

$report = New-Object System.Collections.Generic.List[object]
foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    $subTags = (Get-AzTag -ResourceId "/subscriptions/$($sub.Id)" -ErrorAction SilentlyContinue).Properties.TagsProperty
    $wholeSub = $AllScopes -or (Get-TagValue $subTags $TagName) -eq $TagValue
    $gxpPrefixes = if ($wholeSub) { @("/subscriptions/$($sub.Id)/") } else {
        @(Get-AzResourceGroup | Where-Object { (Get-TagValue $_.Tags $TagName) -eq $TagValue } | ForEach-Object { "$($_.ResourceId)/" })
    }
    if (-not $gxpPrefixes) { Write-Verbose "No GxP scope in $($sub.Name)"; continue }
    Write-Host "Checking $($sub.Name)..." -ForegroundColor Cyan

    foreach ($vault in @(Get-AzRecoveryServicesVault)) {
        $vaultTagged = (Get-TagValue $vault.Tags $TagName) -eq $TagValue
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($w in $workloads) {
            try {
                foreach ($i in @(Get-AzRecoveryServicesBackupItem -VaultId $vault.ID -BackupManagementType $w.Management -WorkloadType $w.Workload -ErrorAction Stop)) {
                    $source = if ($i.SourceResourceId) { $i.SourceResourceId } else { $i.VirtualMachineId }
                    $inScope = $false
                    foreach ($p in $gxpPrefixes) { if ("$source/" -like "$p*") { $inScope = $true; break } }
                    if ($inScope -or $vaultTagged) { $items.Add([pscustomobject]@{ Item = $i; Source = $source; Workload = $w.Workload }) }
                }
            } catch { Write-Verbose "$($vault.Name) $($w.Workload): $($_.Exception.Message)" }
        }
        if (-not $items.Count -and -not $vaultTagged) { continue }   # vault protects nothing in GxP scope

        # Restore jobs: the job API accepts at most 30 days per query
        $restores = New-Object System.Collections.Generic.List[object]
        for ($start = $from; $start -lt $now; $start = $start.AddDays(30)) {
            $end = if ($start.AddDays(30) -lt $now) { $start.AddDays(30) } else { $now }
            try {
                foreach ($j in @(Get-AzRecoveryServicesBackupJob -VaultId $vault.ID -Operation Restore -From $start.ToUniversalTime() -To $end.ToUniversalTime() -ErrorAction Stop)) {
                    if ($j.JobId -and @($restores | Where-Object JobId -eq $j.JobId).Count) { continue }   # a job can straddle two windows
                    $restores.Add($j)
                }
            } catch { Write-Warning "Could not read restore jobs for $($vault.Name): $($_.Exception.Message)"; break }
        }

        $softDelete = ''
        try { $softDelete = [string](Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID -ErrorAction Stop).SoftDeleteFeatureState } catch { }
        $immutability = [string]$vault.Properties.ImmutabilitySettings.ImmutabilityState
        if (-not $immutability) { $immutability = 'Not set' }

        $row = New-Row $sub $vault 'Vault'
        $row.Name = $vault.Name
        $row.SoftDelete = $softDelete
        $row.Immutability = $immutability
        $row.RestoresInWindow = $restores.Count
        $flags = @()
        if ($softDelete -and $softDelete -notmatch 'Enabled|AlwaysON') { $flags += 'Soft delete off' }
        if ($immutability -ne 'Locked') { $flags += 'Immutability not locked' }
        if (-not @($restores | Where-Object { $_.Status -eq 'Completed' }).Count) { $flags += "No completed restore in $Days days" }
        $row.Flags = $flags -join '; '
        $report.Add([pscustomobject]$row)

        foreach ($x in $items) {
            $i = $x.Item
            $row = New-Row $sub $vault 'Item'
            $row.Name = $i.FriendlyName
            if (-not $row.Name) { $row.Name = $i.Name }
            $row.WorkloadType = $x.Workload
            $row.SourceResourceId = $x.Source
            $row.Status = [string]$i.LastBackupStatus
            $row.LastBackup = $i.LastBackupTime
            $flags = @()
            if ([string]$i.ProtectionState -match 'Stop|Protection(Error|Paused)') { $flags += "Protection state: $($i.ProtectionState)" }
            if (-not $i.LastBackupTime -or $i.LastBackupTime -lt $now.AddHours(-$StaleHours).ToUniversalTime()) { $flags += "No backup in $StaleHours hours" }
            if ($i.LastBackupStatus -and [string]$i.LastBackupStatus -notmatch 'Completed|Success|Healthy') { $flags += "Last backup: $($i.LastBackupStatus)" }
            $row.Flags = $flags -join '; '
            $report.Add([pscustomobject]$row)
        }

        foreach ($j in $restores) {
            $row = New-Row $sub $vault 'Restore'
            $row.Name = $j.WorkloadName
            $row.WorkloadType = [string]$j.BackupManagementType
            $row.Status = [string]$j.Status
            $row.RestoreStart = $j.StartTime
            $row.RestoreEnd = $j.EndTime
            $row.DurationMinutes = if ($j.EndTime) { [math]::Round(($j.EndTime - $j.StartTime).TotalMinutes) } else { $null }
            $row.StartedBy = if ($j.PSObject.Properties['User']) { $j.User } else { '' }
            $row.Flags = if ($j.Status -ne 'Completed') { "Restore $($j.Status)" } else { '' }
            $report.Add([pscustomobject]$row)
        }
    }
}

if (-not $report.Count) { Write-Warning "No vaults protect GxP scope. Tag subscriptions or resource groups $TagName = $TagValue, or use -AllScopes."; return }

$order = @{ 'Vault' = 0; 'Item' = 1; 'Restore' = 2 }
$report | Sort-Object Subscription, Vault, @{e = { $order[$_.RecordType] }}, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters

[pscustomobject]@{
    Vaults              = @($report | Where-Object RecordType -eq 'Vault').Count
    VaultsWithFlags     = @($report | Where-Object { $_.RecordType -eq 'Vault' -and $_.Flags }).Count
    ProtectedItems      = @($report | Where-Object RecordType -eq 'Item').Count
    ItemsWithFlags      = @($report | Where-Object { $_.RecordType -eq 'Item' -and $_.Flags }).Count
    RestoreJobs         = @($report | Where-Object RecordType -eq 'Restore').Count
} | Format-List | Out-Host
Write-Host "Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

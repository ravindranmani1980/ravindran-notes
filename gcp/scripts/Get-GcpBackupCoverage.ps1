<#
.SYNOPSIS
    Shows which Compute Engine VMs and Cloud SQL instances are protected by backups, and which aren't.

.DESCRIPTION
    For each project, reports every VM and Cloud SQL instance with its protection:
    - VMs: Backup and DR (a backup plan association), Snapshot schedule (every disk has a
      snapshot schedule), Partial (some disks only), or Not protected
    - Cloud SQL: Backup and DR, Backups + PITR (automated backups and point-in-time
      recovery), Backups only, or Not protected
    For Backup and DR, the time of the last successful backup is shown, and resources whose
    last backup is older than -StaleDays are marked Stale.

    Read-only: it doesn't change anything.

.PARAMETER ProjectId
    Projects to check. Default: every active project you can see.

.PARAMETER ResourceType
    Which resource types to check: VM, CloudSQL. Default: both.

.PARAMETER StaleDays
    A Backup and DR resource whose last successful backup is older than this is Stale. Default 2.

.PARAMETER UnprotectedOnly
    Only list resources that are Not protected, Partial or Stale.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpBackupCoverage.ps1

.EXAMPLE
    .\Get-GcpBackupCoverage.ps1 -ProjectId prj-notes-test -ResourceType VM -UnprotectedOnly

.NOTES
    Requires the Google Cloud CLI (gcloud) and viewer access to Compute Engine, Cloud SQL and
    Backup and DR (roles/backupdr.viewer) in the projects. If the Backup and DR API isn't
    enabled in a project, only snapshot schedules and Cloud SQL backups are counted there.
    Snapshots taken by other tools aren't counted, so check those before acting on the report.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [ValidateSet('VM', 'CloudSQL')][string[]]$ResourceType = @('VM', 'CloudSQL'),
    [ValidateRange(1, 365)][int]$StaleDays = 2,
    [switch]$UnprotectedOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpBackupCoverage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { throw 'gcloud not found. Install the Google Cloud CLI and run gcloud auth login.' }

function Invoke-Gcloud {
    # Runs gcloud with JSON output and returns the result as objects. Throws on a gcloud error.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & gcloud @Arguments --format=json --quiet 2>&1
    $code = $LASTEXITCODE
    $text = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0) {
        $message = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        throw "gcloud $($Arguments[0..1] -join ' ') failed: $message"
    }
    if ($text) { foreach ($item in ($text | ConvertFrom-Json)) { $item } }
}

function Get-TargetProject {
    # The projects to report on: -ProjectId if given, otherwise every active project you can see
    param([string[]]$ProjectId)
    if ($ProjectId) { return $ProjectId }
    @(Invoke-Gcloud @('projects', 'list', '--filter=lifecycleState:ACTIVE') | ForEach-Object { $_.projectId })
}

function Get-Leaf {
    # Last part of a resource URL, for example the zone name from a zone URL
    param([string]$Url)
    if ($Url) { ($Url -split '/')[-1] } else { '' }
}

# Latest successful backup time from a backup plan association, or $null
function Get-LastBackup {
    param($Association)
    $times = @($Association.rulesConfigInfo) | Where-Object { $_ -and $_.lastSuccessfulBackupConsistencyTime } |
        ForEach-Object { [datetime]::Parse($_.lastSuccessfulBackupConsistencyTime, [cultureinfo]::InvariantCulture) }
    $times | Sort-Object -Descending | Select-Object -First 1
}

$report = New-Object System.Collections.Generic.List[object]
$staleCutoff = (Get-Date).AddDays(-$StaleDays)

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan

    $associations = @()
    try {
        $associations = @(Invoke-Gcloud @('backup-dr', 'backup-plan-associations', 'list', "--project=$p")) | Where-Object { $_ }
    } catch {
        Write-Warning "Backup and DR not readable in $p (API not enabled or no access); counting snapshot schedules and Cloud SQL backups only."
    }
    function Find-Association {
        param([string]$Pattern)
        $associations | Where-Object { [string]$_.resource -match $Pattern } | Select-Object -First 1
    }

    if ($ResourceType -contains 'VM') {
        try {
            $vms = @(Invoke-Gcloud @('compute', 'instances', 'list', "--project=$p"))
            $disks = @(Invoke-Gcloud @('compute', 'disks', 'list', "--project=$p"))
        } catch {
            Write-Warning "Skipping VMs in $p`: $($_.Exception.Message)"
            $vms = @()
        }
        $scheduled = @{}
        foreach ($d in $disks) { if ($d -and $d.resourcePolicies) { $scheduled[([string]$d.selfLink).ToLower()] = $true } }

        foreach ($vm in $vms | Where-Object { $_ }) {
            $assoc = Find-Association "/instances/($([regex]::Escape($vm.name))|$($vm.id))$"
            $vmDisks = @($vm.disks | Where-Object { $_ })
            $covered = @($vmDisks | Where-Object { $scheduled[([string]$_.source).ToLower()] }).Count
            $last = $null
            if ($assoc) {
                $last = Get-LastBackup $assoc
                $status = if ($last -and $last -lt $staleCutoff) { 'Stale' } else { 'Backup and DR' }
            } elseif ($vmDisks.Count -and $covered -eq $vmDisks.Count) {
                $status = 'Snapshot schedule'
            } elseif ($covered) {
                $status = "Partial ($covered of $($vmDisks.Count) disks)"
            } else {
                $status = 'Not protected'
            }
            if ($UnprotectedOnly -and $status -in 'Backup and DR', 'Snapshot schedule') { continue }
            $report.Add([pscustomobject]@{
                Project = $p; Type = 'VM'; Name = $vm.name; Location = Get-Leaf $vm.zone; Status = $status
                LastBackup = $last; Detail = ('{0} disk(s), {1} with a snapshot schedule' -f $vmDisks.Count, $covered)
                Owner = $vm.labels.owner
            })
        }
    }

    if ($ResourceType -contains 'CloudSQL') {
        try {
            $sqls = @(Invoke-Gcloud @('sql', 'instances', 'list', "--project=$p"))
        } catch {
            Write-Warning "Skipping Cloud SQL in $p`: $($_.Exception.Message)"
            $sqls = @()
        }
        foreach ($db in $sqls | Where-Object { $_ -and $_.instanceType -ne 'READ_REPLICA_INSTANCE' }) {
            $cfg = $db.settings.backupConfiguration
            $pitr = [bool]($cfg.pointInTimeRecoveryEnabled -or $cfg.binaryLogEnabled)
            $assoc = Find-Association "sqladmin.*/instances/$([regex]::Escape($db.name))$"
            $last = $null
            if ($assoc) {
                $last = Get-LastBackup $assoc
                $status = if ($last -and $last -lt $staleCutoff) { 'Stale' } else { 'Backup and DR' }
            } elseif ($cfg.enabled -and $pitr) { $status = 'Backups + PITR' }
            elseif ($cfg.enabled) { $status = 'Backups only' }
            else { $status = 'Not protected' }
            if ($UnprotectedOnly -and $status -in 'Backup and DR', 'Backups + PITR') { continue }
            $retained = $cfg.backupRetentionSettings.retainedBackups
            $report.Add([pscustomobject]@{
                Project = $p; Type = 'Cloud SQL'; Name = $db.name; Location = $db.region; Status = $status
                LastBackup = $last; Detail = ('{0}, backups {1}, PITR {2}{3}' -f $db.databaseVersion, $(if ($cfg.enabled) { 'on' } else { 'off' }), $(if ($pitr) { 'on' } else { 'off' }), $(if ($retained) { ", keeps $retained" } else { '' }))
                Owner = $db.settings.userLabels.owner
            })
        }
    }
}

$order = @{ 'Not protected' = 0; 'Stale' = 1; 'Backups only' = 2 }
$report | Sort-Object @{e = { if ($order.ContainsKey($_.Status)) { $order[$_.Status] } elseif ($_.Status -like 'Partial*') { 1 } else { 3 } }}, Project, Type, Name |
    Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Type, Status | Select-Object @{n='Type, status';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Resources reported: $($report.Count). Report: $OutputFile" -ForegroundColor Green

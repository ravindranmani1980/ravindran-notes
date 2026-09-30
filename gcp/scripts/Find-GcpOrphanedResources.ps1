<#
.SYNOPSIS
    Finds orphaned Google Cloud resources that cost money or clutter: unattached disks, unused static IPs, old snapshots and more.

.DESCRIPTION
    Checks every project for:
    - Persistent disks that aren't attached to any VM
    - Reserved external IP addresses that aren't in use
    - Snapshots older than -SnapshotAgeDays
    - VMs stopped (TERMINATED) for more than -StoppedDays days
    - Load balancer backend services with no backends

    Read-only: it doesn't delete anything. Review the list with the resource owners,
    then delete what's no longer needed.

.PARAMETER ProjectId
    Projects to check. Default: every active project you can see.

.PARAMETER SnapshotAgeDays
    Report snapshots older than this many days. Default 90.

.PARAMETER StoppedDays
    Report VMs stopped for longer than this many days. Default 30.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Find-GcpOrphanedResources.ps1

.EXAMPLE
    .\Find-GcpOrphanedResources.ps1 -ProjectId prj-notes-test -SnapshotAgeDays 30 -OutputFile .\orphans.csv

.NOTES
    Requires the Google Cloud CLI (gcloud) and roles/compute.viewer (or roles/viewer) on the
    projects. Some "orphans" are intentional (a disk kept after a VM was deleted, a reserved
    IP a partner has allow-listed, a snapshot kept for compliance): check the labels and ask
    the owner before deleting. Recommender's idle-resource recommendations are a useful
    second opinion.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [ValidateRange(1, 3650)][int]$SnapshotAgeDays = 90,
    [ValidateRange(1, 3650)][int]$StoppedDays = 30,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpOrphanedResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

$report = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param($Finding, $Project, $Location, $Name, $Detail, $Labels)
    $report.Add([pscustomobject]@{
        Finding = $Finding; Project = $Project; Location = $Location; Name = $Name; Detail = $Detail; Owner = $Labels.owner
    })
}
function ConvertTo-Date {
    param([string]$Value)
    if ($Value) { [datetime]::Parse($Value, [cultureinfo]::InvariantCulture) } else { $null }
}

$snapshotCutoff = (Get-Date).AddDays(-$SnapshotAgeDays)
$stoppedCutoff = (Get-Date).AddDays(-$StoppedDays)

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan
    try {
        $disks = @(Invoke-Gcloud @('compute', 'disks', 'list', "--project=$p"))
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }

    # Unattached disks
    foreach ($d in $disks | Where-Object { -not $_.users }) {
        $detail = '{0}, {1} GB, created {2:yyyy-MM-dd}' -f (Get-Leaf $d.type), $d.sizeGb, (ConvertTo-Date $d.creationTimestamp)
        if ($d.lastDetachTimestamp) { $detail += ', detached {0:yyyy-MM-dd}' -f (ConvertTo-Date $d.lastDetachTimestamp) }
        Add-Finding 'Unattached disk' $p (Get-Leaf $(if ($d.zone) { $d.zone } else { $d.region })) $d.name $detail $d.labels
    }

    # Reserved external IPs not in use
    foreach ($a in @(Invoke-Gcloud @('compute', 'addresses', 'list', "--project=$p")) |
             Where-Object { $_.status -eq 'RESERVED' -and $_.addressType -ne 'INTERNAL' }) {
        Add-Finding 'Unused static external IP' $p $(if ($a.region) { Get-Leaf $a.region } else { 'global' }) $a.name $a.address $a.labels
    }

    # Old snapshots
    foreach ($s in @(Invoke-Gcloud @('compute', 'snapshots', 'list', "--project=$p")) |
             Where-Object { (ConvertTo-Date $_.creationTimestamp) -lt $snapshotCutoff }) {
        $stored = if ($s.storageBytes) { [math]::Round([double]$s.storageBytes / 1GB, 1) } else { 0 }
        $detail = 'from {0} ({1} GB disk), {2} GB stored, created {3:yyyy-MM-dd}' -f (Get-Leaf $s.sourceDisk), $s.diskSizeGb, $stored, (ConvertTo-Date $s.creationTimestamp)
        if ($s.autoCreated) { $detail += ', from a snapshot schedule' }
        Add-Finding 'Old snapshot' $p (@($s.storageLocations) -join ',') $s.name $detail $s.labels
    }

    # VMs stopped for a long time
    foreach ($vm in @(Invoke-Gcloud @('compute', 'instances', 'list', "--project=$p", '--filter=status=TERMINATED'))) {
        $since = ConvertTo-Date $vm.lastStopTimestamp
        if ($since -and $since -lt $stoppedCutoff) {
            $gb = [int](@($vm.disks) | ForEach-Object { [int]$_.diskSizeGb } | Measure-Object -Sum).Sum
            Add-Finding 'Long-stopped VM' $p (Get-Leaf $vm.zone) $vm.name ('{0}, stopped since {1:yyyy-MM-dd}, {2} GB of disks' -f (Get-Leaf $vm.machineType), $since, $gb) $vm.labels
        }
    }

    # Backend services with no backends
    foreach ($b in @(Invoke-Gcloud @('compute', 'backend-services', 'list', "--project=$p")) | Where-Object { -not $_.backends }) {
        Add-Finding 'Backend service with no backends' $p $(if ($b.region) { Get-Leaf $b.region } else { 'global' }) $b.name `
            ('{0}, {1}' -f $b.loadBalancingScheme, $b.protocol) $null
    }
}

$report | Sort-Object Finding, Project, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Finding | Select-Object @{n='Finding';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Findings: $($report.Count). Report: $OutputFile" -ForegroundColor Green

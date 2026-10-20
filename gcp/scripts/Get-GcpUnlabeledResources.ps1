<#
.SYNOPSIS
    Lists Google Cloud resources that are missing required labels, or have them under a slightly different name.

.DESCRIPTION
    Uses Cloud Asset Inventory to search the common billable resource types (VMs, disks,
    snapshots, images, buckets, Cloud SQL, BigQuery datasets, GKE clusters, Cloud Run services,
    Memorystore and Filestore) and reports every resource where a -RequiredLabel is:
    - missing, or
    - present under a near-miss name (cost_center or cost-center instead of costcenter),
      which splits cost reports in two

    Read-only: it doesn't change any labels.

.PARAMETER RequiredLabel
    Label keys every resource must have. Default: owner, costcenter, environment.

.PARAMETER Scope
    Where to search: organizations/ID, folders/ID or projects/ID. Default: each project in -ProjectId, or every active project you can see.

.PARAMETER ProjectId
    Projects to search when -Scope isn't given.

.PARAMETER AssetType
    Asset types to check. Default: the common billable types listed above.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpUnlabeledResources.ps1 -Scope organizations/123456789012

.EXAMPLE
    .\Get-GcpUnlabeledResources.ps1 -ProjectId prj-notes-test -RequiredLabel owner, costcenter -AssetType compute.googleapis.com/Instance

.NOTES
    Requires the Google Cloud CLI (gcloud), the Cloud Asset API enabled in your current
    project, and roles/cloudasset.viewer at the scope you search. Labels are always lowercase
    in Google Cloud, so near misses are spelling differences rather than capitalisation.
#>
[CmdletBinding()]
param(
    [string[]]$RequiredLabel = @('owner', 'costcenter', 'environment'),
    [string]$Scope,
    [string[]]$ProjectId,
    [string[]]$AssetType = @(
        'compute.googleapis.com/Instance', 'compute.googleapis.com/Disk', 'compute.googleapis.com/Snapshot',
        'compute.googleapis.com/Image', 'storage.googleapis.com/Bucket', 'sqladmin.googleapis.com/Instance',
        'bigquery.googleapis.com/Dataset', 'container.googleapis.com/Cluster', 'run.googleapis.com/Service',
        'redis.googleapis.com/Instance', 'file.googleapis.com/Instance'),
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpUnlabeledResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

# Compare label keys ignoring - and _ so cost-center and cost_center match costcenter
function Get-LabelKeyForm { param([string]$Key) ($Key -replace '[-_]', '').ToLower() }

$report = New-Object System.Collections.Generic.List[object]
$scopes = if ($Scope) { @($Scope) } else { @(Get-TargetProject $ProjectId | ForEach-Object { "projects/$_" }) }

foreach ($s in $scopes) {
    Write-Host "Searching $s..." -ForegroundColor Cyan
    try {
        $assets = @(Invoke-Gcloud @('asset', 'search-all-resources', "--scope=$s", "--asset-types=$($AssetType -join ',')"))
    } catch {
        Write-Warning "Skipping $s`: $($_.Exception.Message)"
        continue
    }
    foreach ($a in $assets) {
        if (-not $a) { continue }
        $keys = @()
        if ($a.labels) { $keys = @($a.labels.PSObject.Properties.Name) }
        $missing = @(); $nearMiss = @()
        foreach ($r in $RequiredLabel) {
            if ($keys -contains $r) { continue }
            $near = $keys | Where-Object { (Get-LabelKeyForm $_) -eq (Get-LabelKeyForm $r) } | Select-Object -First 1
            if ($near) { $nearMiss += "$near (should be $r)" } else { $missing += $r }
        }
        if (-not $missing -and -not $nearMiss) { continue }
        $report.Add([pscustomobject]@{
            Project   = $a.project
            AssetType = ($a.assetType -split '/')[-1]
            Service   = ($a.assetType -split '/')[0]
            Name      = if ($a.displayName) { $a.displayName } else { Get-Leaf $a.name }
            Location  = $a.location
            Missing   = $missing -join ', '
            NearMiss  = $nearMiss -join ', '
            Owner     = if ($a.labels) { $a.labels.owner } else { '' }
            Resource  = $a.name
        })
    }
}

$report | Sort-Object Project, Service, AssetType, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Service, AssetType | Sort-Object Count -Descending | Select-Object @{n='Service, type';e={$_.Name}}, Count |
    Format-Table -AutoSize | Out-Host
Write-Host "Resources missing labels: $($report.Count). Report: $OutputFile" -ForegroundColor Green

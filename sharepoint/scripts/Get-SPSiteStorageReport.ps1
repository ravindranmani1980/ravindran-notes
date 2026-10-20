<#
.SYNOPSIS
    Reports storage, quota use and staleness for every site collection.

.DESCRIPTION
    Lists each site collection with its owner, size, quota, percent of quota used,
    content database, number of webs and last content change. Sites with no content
    changes for -StaleDays days are flagged, which makes cleanup and migration
    scoping conversations much easier. Read-only.

.PARAMETER WebApplication
    Limit the report to one web application URL. Default: all web applications.

.PARAMETER StaleDays
    Days without content changes after which a site is flagged as stale. Default 365.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPSiteStorageReport.ps1 -WebApplication https://sharepoint.ravindran.in -StaleDays 730
#>
[CmdletBinding()]
param(
    [string]$WebApplication,
    [int]$StaleDays = 365,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SiteStorage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Get-SPSite -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPSite -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$cutoff = (Get-Date).AddDays(-$StaleDays)
$sites  = @(if ($WebApplication) { Get-SPSite -WebApplication $WebApplication -Limit All } else { Get-SPSite -Limit All })
$siteCount = [math]::Max($sites.Count, 1)
$results = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($site in $sites) {
    $i++
    Write-Progress -Activity 'Reading site collections' -Status $site.Url -PercentComplete (($i / $siteCount) * 100)
    try {
        $storageMB = [math]::Round($site.Usage.Storage / 1MB, 2)
        $quotaMB   = [math]::Round($site.Quota.StorageMaximumLevel / 1MB, 2)
        $results.Add([pscustomobject]@{
            Url             = $site.Url
            Owner           = $site.Owner.UserLogin
            SecondaryOwner  = $site.SecondaryContact.UserLogin
            StorageMB       = $storageMB
            QuotaMB         = if ($quotaMB -gt 0) { $quotaMB } else { 'No quota' }
            PercentOfQuota  = if ($quotaMB -gt 0) { [math]::Round(($storageMB / $quotaMB) * 100, 1) } else { $null }
            ContentDatabase = $site.ContentDatabase.Name
            WebCount        = $site.AllWebs.Count
            LastModified    = $site.LastContentModifiedDate
            IsStale         = $site.LastContentModifiedDate -lt $cutoff
            LockState       = if ($site.ReadOnly) { 'ReadOnly' } elseif ($site.ReadLocked) { 'NoAccess' } else { 'Unlocked' }
        })
    }
    finally {
        $site.Dispose()
    }
}
Write-Progress -Activity 'Reading site collections' -Completed

$results | Sort-Object StorageMB -Descending | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$totalGB = [math]::Round((($results | Measure-Object StorageMB -Sum).Sum) / 1024, 2)
Write-Host "Site collections: $($results.Count)  Total: $totalGB GB  Stale (> $StaleDays days): $(@($results | Where-Object IsStale).Count)"
Write-Host "Report: $OutputFile" -ForegroundColor Green

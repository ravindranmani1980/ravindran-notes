<#
.SYNOPSIS
    Finds lists and libraries that are approaching or over the list view threshold.

.DESCRIPTION
    Walks every site collection and web, and reports lists with at least -Threshold
    items together with their indexed columns. Use a threshold below the web
    application's list view threshold (default 5,000) as an early warning so you can
    add indexes before users start seeing errors. Read-only.

.PARAMETER Threshold
    Minimum item count to report. Default 4000.

.PARAMETER WebApplication
    Limit to one web application URL. Default: all web applications.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPLargeLists.ps1

.EXAMPLE
    .\Get-SPLargeLists.ps1 -Threshold 20000 -WebApplication https://sharepoint.ravindran.in
#>
[CmdletBinding()]
param(
    [int]$Threshold = 4000,
    [string]$WebApplication,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('LargeLists_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Get-SPSite -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPSite -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$sites   = if ($WebApplication) { Get-SPSite -WebApplication $WebApplication -Limit All } else { Get-SPSite -Limit All }
$results = New-Object System.Collections.Generic.List[object]

foreach ($site in $sites) {
    Write-Verbose "Scanning $($site.Url)"
    try {
        # The real threshold is configured per web application
        $lvt = $site.WebApplication.MaxItemsPerThrottledOperation
        foreach ($web in $site.AllWebs) {
            try {
                foreach ($list in $web.Lists) {
                    if ($list.ItemCount -lt $Threshold) { continue }
                    $indexed = @($list.Fields | Where-Object { $_.Indexed } | ForEach-Object { $_.InternalName })
                    $results.Add([pscustomobject]@{
                        SiteUrl           = $site.Url
                        WebUrl            = $web.Url
                        List              = $list.Title
                        ListUrl           = "$($web.Url.TrimEnd('/'))/$($list.RootFolder.Url)"
                        ItemCount         = $list.ItemCount
                        ListViewThreshold = $lvt
                        OverThreshold     = $list.ItemCount -ge $lvt
                        IndexedColumns    = $indexed -join '; '
                        LastItemModified  = $list.LastItemModifiedDate
                    })
                }
            }
            finally { $web.Dispose() }
        }
    }
    finally { $site.Dispose() }
}

$results | Sort-Object ItemCount -Descending | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Lists with $Threshold+ items: $($results.Count) (over threshold: $(@($results | Where-Object OverThreshold).Count))"
Write-Host "Report: $OutputFile" -ForegroundColor Green

<#
.SYNOPSIS
    Finds large lists and libraries in a SharePoint Online site and shows their indexes.

.DESCRIPTION
    In SharePoint Online the list view threshold is fixed at 5,000 items, but lists can
    hold millions. What keeps large lists working is indexed columns on anything that
    views filter or sort by. This report shows which lists are big and which columns are
    indexed so you can fix views before users see errors. Read-only.

.PARAMETER SiteUrl
    The site to scan.

.PARAMETER ClientId
    Entra ID app (client) ID for PnP. Defaults to $env:PNP_CLIENT_ID.

.PARAMETER Threshold
    Minimum item count to report. Default 4000.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPOListsNearThreshold.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/Projects
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$ClientId = $env:PNP_CLIENT_ID,
    [int]$Threshold = 4000,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SPOLargeLists_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not $ClientId) { throw 'Provide -ClientId or set $env:PNP_CLIENT_ID. See https://notes.ravindran.in/sharepoint/guides/getting-started.html' }
Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive

$lists = Get-PnPList | Where-Object { -not $_.Hidden -and $_.ItemCount -ge $Threshold }

$report = foreach ($list in $lists) {
    $indexed = @(Get-PnPField -List $list | Where-Object { $_.Indexed } | ForEach-Object { $_.InternalName })
    [pscustomobject]@{
        List             = $list.Title
        Type             = $list.BaseType
        ItemCount        = $list.ItemCount
        OverThreshold    = $list.ItemCount -gt 5000
        IndexedColumns   = $indexed -join '; '
        DefaultViewUrl   = $list.DefaultViewUrl
        LastItemModified = $list.LastItemUserModifiedDate
    }
}

if (-not $report) {
    Write-Host "No lists with $Threshold or more items." -ForegroundColor Green
    return
}

$report | Sort-Object ItemCount -Descending | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Sort-Object ItemCount -Descending | Format-Table List, ItemCount, OverThreshold, IndexedColumns -AutoSize | Out-Host
Write-Host 'Tip: add an index with  Set-PnPField -List "<list>" -Identity "<column>" -Values @{Indexed=$true}'
Write-Host "Report: $OutputFile" -ForegroundColor Green

<#
.SYNOPSIS
    Restores items that one user deleted in a time window (mass-deletion recovery).

.DESCRIPTION
    A sync client gone wrong, a user who "cleaned up" the wrong folder, or a compromised
    account can delete thousands of files in minutes. Restoring those one page at a time
    in the browser is painful. This script finds everything in the site's first- and
    second-stage recycle bins deleted by -DeletedBy between -Since and -Until, saves a
    CSV of what it found, and restores it.

    Folders are restored first (shallowest first) so files can go back into them.
    Run with -WhatIf first to see what would be restored.

.PARAMETER SiteUrl
    The affected site.

.PARAMETER DeletedBy
    The email address of the user who deleted the content.

.PARAMETER Since
    Start of the window. Default: 24 hours ago. Local time.

.PARAMETER Until
    End of the window. Default: now. Local time.

.PARAMETER ClientId
    Entra ID app (client) ID for PnP. Defaults to $env:PNP_CLIENT_ID.

.EXAMPLE
    .\Restore-SPORecycleBinByUser.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/Finance -DeletedBy jane@ravindran.in -Since '2026-09-27 08:00' -WhatIf

.EXAMPLE
    .\Restore-SPORecycleBinByUser.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/Finance -DeletedBy jane@ravindran.in -Since '2026-09-27 08:00'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [Parameter(Mandatory)][string]$DeletedBy,
    [datetime]$Since = (Get-Date).AddDays(-1),
    [datetime]$Until = (Get-Date),
    [string]$ClientId = $env:PNP_CLIENT_ID,
    [string]$ReportFile = (Join-Path -Path (Get-Location) -ChildPath ('RecycleBinRestore_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not $ClientId) { throw 'Provide -ClientId or set $env:PNP_CLIENT_ID. See https://notes.ravindran.in/sharepoint/guides/getting-started.html' }
Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive

# Recycle bin dates are stored in UTC
$sinceUtc = $Since.ToUniversalTime()
$untilUtc = $Until.ToUniversalTime()

Write-Host 'Reading recycle bin...' -ForegroundColor Cyan
$items = @(Get-PnPRecycleBinItem | Where-Object {
    $_.DeletedByEmail -eq $DeletedBy -and
    $_.DeletedDate.ToUniversalTime() -ge $sinceUtc -and
    $_.DeletedDate.ToUniversalTime() -le $untilUtc
})

if ($items.Count -eq 0) {
    Write-Warning "Nothing found deleted by $DeletedBy between $Since and $Until."
    return
}

# Folders first, shallowest path first, then everything else
$ordered = $items | Sort-Object `
    @{ Expression = { if ($_.ItemType -eq 'Folder') { 0 } else { 1 } } },
    @{ Expression = { ($_.DirName -split '/').Count } }

$log = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($item in $ordered) {
    $i++
    $path = "$($item.DirName)/$($item.LeafName)"
    Write-Progress -Activity 'Restoring' -Status $path -PercentComplete (($i / $items.Count) * 100)
    $result = 'WhatIf'
    if ($PSCmdlet.ShouldProcess($path, 'Restore from recycle bin')) {
        try {
            Restore-PnPRecycleBinItem -Identity $item.Id -Force -ErrorAction Stop
            $result = 'Restored'
        }
        catch {
            # Items inside a folder that was already restored disappear from the bin; that's fine
            $result = "Failed: $($_.Exception.Message)"
        }
    }
    $log.Add([pscustomobject]@{
        Path        = $path
        ItemType    = $item.ItemType
        DeletedDate = $item.DeletedDate
        Stage       = $item.ItemState
        SizeMB      = [math]::Round($item.Size / 1MB, 2)
        Result      = $result
    })
}
Write-Progress -Activity 'Restoring' -Completed

$log | Export-Csv -Path $ReportFile -NoTypeInformation -Encoding UTF8
$log | Group-Object { ($_.Result -split ':')[0] } | Select-Object Name, Count | Format-Table -AutoSize | Out-Host
Write-Host "Report: $ReportFile" -ForegroundColor Green

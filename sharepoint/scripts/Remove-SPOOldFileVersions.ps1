<#
.SYNOPSIS
    Trims old file versions in a document library, keeping the newest N versions.

.DESCRIPTION
    For every file in the library, keeps the current version plus the newest
    -KeepVersions previous versions and deletes the older ones. Reports how much
    storage the removed versions used.

    THIS DELETES DATA. Always run with -WhatIf first and review the log. Depending on
    your PnP.PowerShell version, deleted versions may go to the site recycle bin, in
    which case storage is only freed once the recycle bins are emptied.

    For tenant-wide or site-wide version cleanup, also look at the built-in options
    described in the SharePoint Online tips guide (tip 9):
    https://notes.ravindran.in/sharepoint/guides/sharepoint-online-tips.html

.PARAMETER SiteUrl
    The site containing the library.

.PARAMETER Library
    Library title, e.g. 'Documents'.

.PARAMETER KeepVersions
    Number of previous versions to keep per file (the current version is always kept). Default 10.

.PARAMETER ClientId
    Entra ID app (client) ID for PnP. Defaults to $env:PNP_CLIENT_ID.

.PARAMETER LogFile
    CSV log of every version removed (or that would be removed with -WhatIf).

.EXAMPLE
    .\Remove-SPOOldFileVersions.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/Eng -Library Documents -KeepVersions 5 -WhatIf

.EXAMPLE
    .\Remove-SPOOldFileVersions.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/Eng -Library Documents -KeepVersions 5 -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [Parameter(Mandatory)][string]$Library,
    [ValidateRange(1, 500)][int]$KeepVersions = 10,
    [string]$ClientId = $env:PNP_CLIENT_ID,
    [string]$LogFile = (Join-Path -Path (Get-Location) -ChildPath ('VersionCleanup_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not $ClientId) { throw 'Provide -ClientId or set $env:PNP_CLIENT_ID. See https://notes.ravindran.in/sharepoint/guides/getting-started.html' }
Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive

Write-Host "Reading files in '$Library'..." -ForegroundColor Cyan
$files = @(Get-PnPListItem -List $Library -PageSize 500 -Fields FileRef, FileLeafRef |
    Where-Object { $_.FileSystemObjectType -eq 'File' })

$log = New-Object System.Collections.Generic.List[object]
$bytes = 0L
$i = 0

foreach ($file in $files) {
    $i++
    $fileUrl = $file.FieldValues['FileRef']
    Write-Progress -Activity 'Checking versions' -Status $fileUrl -PercentComplete (($i / [math]::Max($files.Count, 1)) * 100)

    # Previous versions only; the current version is never in this list
    $versions = @(Get-PnPFileVersion -Url $fileUrl)
    $excess = $versions.Count - $KeepVersions
    if ($excess -le 0) { continue }

    $oldest = $versions | Sort-Object Created | Select-Object -First $excess
    foreach ($v in $oldest) {
        $action = 'WhatIf'
        if ($PSCmdlet.ShouldProcess("$fileUrl (version $($v.VersionLabel))", 'Delete file version')) {
            try {
                Remove-PnPFileVersion -Url $fileUrl -Identity $v.Id -Force -ErrorAction Stop
                $action = 'Removed'
            }
            catch {
                $action = "Failed: $($_.Exception.Message)"
            }
        }
        if ($action -in 'Removed', 'WhatIf') { $bytes += [int64]$v.Size }
        $log.Add([pscustomobject]@{
            File     = $fileUrl
            Version  = $v.VersionLabel
            Created  = $v.Created
            SizeMB   = [math]::Round($v.Size / 1MB, 2)
            Action   = $action
        })
    }
}
Write-Progress -Activity 'Checking versions' -Completed

$log | Export-Csv -Path $LogFile -NoTypeInformation -Encoding UTF8
$verb = if ($WhatIfPreference) { 'would be removed' } else { 'processed' }
Write-Host ("Files scanned: {0}  Versions {1}: {2}  Storage: {3:N2} GB" -f $files.Count, $verb, $log.Count, ($bytes / 1GB))
Write-Host "Log: $LogFile" -ForegroundColor Green

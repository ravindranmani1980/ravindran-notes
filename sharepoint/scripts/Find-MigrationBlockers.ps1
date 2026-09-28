<#
.SYNOPSIS
    Scans a file share (or any folder) for problems that block or complicate a move to
    SharePoint Online / OneDrive.

.DESCRIPTION
    Checks every file and folder for:
    - Blocker: invalid characters  " * : < > ? / \ |
    - Blocker: reserved names (CON, PRN, AUX, NUL, COM0-9, LPT0-9), .lock, desktop.ini, names starting with ~$, names containing _vti_
    - Blocker: leading or trailing spaces
    - Blocker: a folder named 'forms' at the library root
    - Blocker: decoded path in SharePoint longer than -MaxPathLength (400)
    - Blocker: files larger than -MaxFileSizeBytes (250 GB)
    - Warning: folders that could not be read (access denied)
    - Info: common junk files (Thumbs.db, .DS_Store, ~*.tmp) worth cleaning up

    The path length check adds your target library path (e.g. sites/Finance/Shared Documents)
    in front of each relative path, because that's what counts toward the limit once the
    content is in SharePoint. Read-only; nothing is renamed or changed.

    Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Path
    The folder or share to scan, e.g. \\fileserver\Departments\Finance.

.PARAMETER TargetLibraryUrl
    Full URL of the destination library, used for the path length calculation.

.PARAMETER MaxPathLength
    Maximum decoded path length. Default 400 (the SharePoint Online limit).

.PARAMETER MaxFileSizeBytes
    Maximum file size. Default 250GB.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Find-MigrationBlockers.ps1 -Path \\fs01\Finance -TargetLibraryUrl "https://sharepointonline.ravindran.in/sites/Finance/Shared Documents"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Path,

    [string]$TargetLibraryUrl = 'https://sharepointonline.ravindran.in/sites/Migration/Shared Documents',
    [int]$MaxPathLength = 400,
    [long]$MaxFileSizeBytes = 250GB,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('MigrationBlockers_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

$root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\', '/')
# Decoded server-relative path of the target library, without the leading slash
$targetPrefix = [uri]::UnescapeDataString(([uri]$TargetLibraryUrl).AbsolutePath).Trim('/')

$invalidCharPattern = '["*:<>?/\\|]'
$reservedPattern    = '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.[^.]*)?$'
$blockedNames       = @('.lock', 'desktop.ini')
$junkPatterns       = @('Thumbs.db', '.DS_Store', '~*.tmp', 'ehthumbs.db')

$issues = New-Object System.Collections.Generic.List[object]
function Add-Issue {
    param($Severity, $Issue, $Item, $Detail)
    $issues.Add([pscustomobject]@{
        Severity = $Severity
        Issue    = $Issue
        Type     = if ($Item.PSIsContainer) { 'Folder' } else { 'File' }
        Path     = $Item.FullName
        Detail   = $Detail
    })
}

Write-Host "Scanning $root ..." -ForegroundColor Cyan
$scanErrors = $null
$count = 0

Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors |
ForEach-Object {
    $item = $_
    $name = $item.Name
    $count++
    if ($count % 5000 -eq 0) { Write-Progress -Activity 'Scanning' -Status "$count items checked" }

    $relative   = ($item.FullName.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
    $targetPath = "$targetPrefix/$relative"

    if ($name -match $invalidCharPattern) {
        Add-Issue 'Blocker' 'Invalid character' $item "Name contains one of: `" * : < > ? / \ |"
    }
    if ($name -match $reservedPattern) {
        Add-Issue 'Blocker' 'Reserved name' $item $name
    }
    if ($blockedNames -contains $name) {
        Add-Issue 'Blocker' 'Blocked name' $item $name
    }
    if ($name.StartsWith('~$')) {
        Add-Issue 'Blocker' 'Starts with ~$' $item 'Usually an Office owner/lock file; safe to delete if the document is closed'
    }
    if ($name -like '*_vti_*') {
        Add-Issue 'Blocker' 'Contains _vti_' $item $name
    }
    if ($name -ne $name.Trim()) {
        Add-Issue 'Blocker' 'Leading/trailing space' $item "'$name'"
    }
    if ($item.PSIsContainer -and $name -eq 'forms' -and $relative -notmatch '/') {
        Add-Issue 'Blocker' "Root folder named 'forms'" $item 'Rename before migrating'
    }
    if ($targetPath.Length -gt $MaxPathLength) {
        Add-Issue 'Blocker' 'Path too long' $item "$($targetPath.Length) characters in SharePoint (limit $MaxPathLength)"
    }
    if (-not $item.PSIsContainer) {
        if ($item.Length -gt $MaxFileSizeBytes) {
            Add-Issue 'Blocker' 'File too large' $item ('{0:N1} GB' -f ($item.Length / 1GB))
        }
        foreach ($pattern in $junkPatterns) {
            if ($name -like $pattern) { Add-Issue 'Info' 'Junk file' $item 'Candidate for cleanup'; break }
        }
    }
}
Write-Progress -Activity 'Scanning' -Completed

foreach ($err in $scanErrors) {
    $issues.Add([pscustomobject]@{
        Severity = 'Warning'
        Issue    = 'Could not read'
        Type     = 'Folder'
        Path     = $err.TargetObject
        Detail   = $err.Exception.Message
    })
}

$issues | Sort-Object Severity, Issue, Path | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "Items scanned: $count   Issues found: $($issues.Count)"
if ($issues.Count -gt 0) {
    $issues | Group-Object Severity, Issue | Sort-Object Count -Descending |
        Select-Object Count, @{n='Severity / Issue';e={$_.Name}} | Format-Table -AutoSize | Out-Host
}
Write-Host "Report: $OutputFile" -ForegroundColor Green

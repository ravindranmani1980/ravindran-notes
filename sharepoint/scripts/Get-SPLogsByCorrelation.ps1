<#
.SYNOPSIS
    Collects ULS log entries for a correlation ID from the whole farm.

.DESCRIPTION
    Uses Merge-SPLogFile to gather matching entries from every server into one file,
    so you don't have to open ULS logs server by server. Use -LocalOnly to search just
    the current server with Get-SPLogEvent, which is faster when you know where the
    error happened.

.PARAMETER CorrelationId
    The correlation ID from the error page.

.PARAMETER StartTime
    Start of the search window. Default: 1 hour ago. Narrow windows are much faster.

.PARAMETER EndTime
    End of the search window. Default: now.

.PARAMETER LocalOnly
    Search only the local server's ULS logs.

.PARAMETER OutputFile
    Output path. Default: .\ULS_<CorrelationId>.log (or .csv with -LocalOnly).

.EXAMPLE
    .\Get-SPLogsByCorrelation.ps1 -CorrelationId 3f2a9c4e-1b7d-4e0a-9f1e-8c2b5d6a7e90

.EXAMPLE
    .\Get-SPLogsByCorrelation.ps1 -CorrelationId 3f2a9c4e-1b7d-4e0a-9f1e-8c2b5d6a7e90 -StartTime '2024-03-01 09:00' -EndTime '2024-03-01 09:30' -LocalOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CorrelationId,
    [datetime]$StartTime = (Get-Date).AddHours(-1),
    [datetime]$EndTime = (Get-Date),
    [switch]$LocalOnly,
    [string]$OutputFile
)

if (-not (Get-Command Merge-SPLogFile -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Merge-SPLogFile -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

if ($LocalOnly) {
    if (-not $OutputFile) { $OutputFile = Join-Path (Get-Location) "ULS_$CorrelationId.csv" }
    Write-Host "Searching local ULS logs from $StartTime to $EndTime..." -ForegroundColor Cyan
    $entries = Get-SPLogEvent -StartTime $StartTime -EndTime $EndTime |
        Where-Object { $_.Correlation -eq $CorrelationId } |
        Select-Object Timestamp, Process, Area, Category, EventID, Level, Message

    if (-not $entries) { Write-Warning 'No entries found on this server. Try widening the time window or drop -LocalOnly.'; return }

    $entries | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    # Show the most useful lines straight away
    $entries | Where-Object { $_.Level -in 'Unexpected', 'Critical', 'High', 'Exception' } |
        Format-Table Timestamp, Level, Category, Message -Wrap | Out-Host
}
else {
    if (-not $OutputFile) { $OutputFile = Join-Path (Get-Location) "ULS_$CorrelationId.log" }
    Write-Host "Merging ULS logs from all farm servers from $StartTime to $EndTime..." -ForegroundColor Cyan
    Merge-SPLogFile -Path $OutputFile -Correlation $CorrelationId -StartTime $StartTime -EndTime $EndTime -Overwrite
}

if (Test-Path $OutputFile) { Write-Host "Saved: $OutputFile" -ForegroundColor Green }
else { Write-Warning 'No matching entries were found. Check the time window (ULS uses server local time).' }

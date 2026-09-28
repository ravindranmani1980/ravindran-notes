<#
.SYNOPSIS
    Shows which SharePoint services run on which servers, as a matrix.

.DESCRIPTION
    Builds a grid of service instances (rows) by servers (columns) showing where each
    service is Online. Also lists each server's MinRole role and whether it is compliant
    with that role (2016 and later). Use it to document a farm, check a design, or find
    services someone started by hand. Read-only.

.PARAMETER IncludeStopped
    Also list services that are not online anywhere.

.PARAMETER OutputFile
    CSV output path for the matrix.

.EXAMPLE
    .\Get-SPServiceMatrix.ps1

.EXAMPLE
    .\Get-SPServiceMatrix.ps1 -OutputFile D:\Reports\ServiceMatrix.csv
#>
[CmdletBinding()]
param(
    [switch]$IncludeStopped,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('ServiceMatrix_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Get-SPServer -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPServer -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$servers = @(Get-SPServer | Where-Object {
    $_.ServiceInstances | Where-Object { $_.GetType().Name -eq 'SPTimerServiceInstance' }
} | Sort-Object Address)

# Server summary
$servers | Select-Object @{n='Server';e={$_.Address}}, Role,
    @{n='CompliantWithMinRole';e={ if ($_.PSObject.Properties['CompliantWithMinRole']) { $_.CompliantWithMinRole } else { 'n/a (before 2016)' } }} |
    Format-Table -AutoSize | Out-Host

# Collect status per service type name and server
$status = @{}
foreach ($server in $servers) {
    foreach ($si in $server.ServiceInstances) {
        $type = $si.TypeName
        if (-not $status.ContainsKey($type)) { $status[$type] = @{} }
        $status[$type][$server.Address] = [string]$si.Status
    }
}

$matrix = foreach ($type in ($status.Keys | Sort-Object)) {
    $online = @($status[$type].Values | Where-Object { $_ -eq 'Online' }).Count
    if (-not $IncludeStopped -and $online -eq 0) { continue }
    $row = [ordered]@{ Service = $type; OnlineOn = $online }
    foreach ($server in $servers) {
        $s = $status[$type][$server.Address]
        $row[$server.Address] = if ($s -eq 'Online') { 'Online' } elseif ($s) { '-' } else { '' }
    }
    [pscustomobject]$row
}

$matrix | Format-Table -AutoSize | Out-Host
$matrix | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Matrix: $OutputFile (open in Excel for the full grid)" -ForegroundColor Green

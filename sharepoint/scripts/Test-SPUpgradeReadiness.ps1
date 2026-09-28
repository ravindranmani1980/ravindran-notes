<#
.SYNOPSIS
    Runs Test-SPContentDatabase and produces one readable report for upgrade planning.

.DESCRIPTION
    Attached mode (default): tests every content database already mounted in this farm,
    or only those of one web application. Use it before patching or before detaching
    databases to move to a new version.

    Unattached mode: tests a database that is restored to SQL but not yet mounted,
    against a web application in this (target) farm. This is the check to run before
    Mount-SPContentDatabase during a version-to-version upgrade.

    Pay the most attention to rows where UpgradeBlocking is True. Missing features,
    web parts and setup files are usually leftovers from old custom solutions.

.PARAMETER WebApplication
    Attached mode: limit to one web application URL.

.PARAMETER DatabaseName
    Unattached mode: the database name on SQL Server.

.PARAMETER DatabaseServer
    Unattached mode: SQL server or alias.

.PARAMETER TargetWebApplication
    Unattached mode: the web application the database will be mounted to.

.EXAMPLE
    .\Test-SPUpgradeReadiness.ps1 -WebApplication https://sharepoint.ravindran.in

.EXAMPLE
    .\Test-SPUpgradeReadiness.ps1 -DatabaseName WSS_Content_Portal -DatabaseServer SQL01 -TargetWebApplication https://sharepoint.ravindran.in
#>
[CmdletBinding(DefaultParameterSetName = 'Attached')]
param(
    [Parameter(ParameterSetName = 'Attached')][string]$WebApplication,
    [Parameter(ParameterSetName = 'Unattached', Mandatory)][string]$DatabaseName,
    [Parameter(ParameterSetName = 'Unattached', Mandatory)][string]$DatabaseServer,
    [Parameter(ParameterSetName = 'Unattached', Mandatory)][string]$TargetWebApplication,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('UpgradeReadiness_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Test-SPContentDatabase -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Test-SPContentDatabase -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

function ConvertTo-ReportRow {
    param($DatabaseName, $Result)
    [pscustomobject]@{
        Database        = $DatabaseName
        Category        = $Result.Category
        UpgradeBlocking = $Result.UpgradeBlocking
        Error           = $Result.Error
        Message         = $Result.Message
        Remedy          = $Result.Remedy
        Locations       = ($Result.Locations | Out-String).Trim()
    }
}

$rows = New-Object System.Collections.Generic.List[object]

if ($PSCmdlet.ParameterSetName -eq 'Unattached') {
    Write-Host "Testing unattached database $DatabaseName on $DatabaseServer against $TargetWebApplication..." -ForegroundColor Cyan
    $results = Test-SPContentDatabase -Name $DatabaseName -ServerInstance $DatabaseServer -WebApplication $TargetWebApplication
    foreach ($r in $results) { $rows.Add((ConvertTo-ReportRow -DatabaseName $DatabaseName -Result $r)) }
    if (-not $results) { $rows.Add([pscustomobject]@{ Database = $DatabaseName; Category = 'None'; Message = 'No issues found' }) }
}
else {
    $dbs = if ($WebApplication) { Get-SPContentDatabase -WebApplication $WebApplication } else { Get-SPContentDatabase }
    foreach ($db in $dbs) {
        Write-Host "Testing $($db.Name)..." -ForegroundColor Cyan
        $results = Test-SPContentDatabase -Identity $db
        foreach ($r in $results) { $rows.Add((ConvertTo-ReportRow -DatabaseName $db.Name -Result $r)) }
        if (-not $results) { $rows.Add([pscustomobject]@{ Database = $db.Name; Category = 'None'; Message = 'No issues found' }) }
    }
}

$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$rows | Group-Object Database | ForEach-Object {
    [pscustomobject]@{
        Database = $_.Name
        Issues   = @($_.Group | Where-Object { $_.Category -ne 'None' }).Count
        Blocking = @($_.Group | Where-Object { $_.UpgradeBlocking -eq $true }).Count
    }
} | Format-Table -AutoSize | Out-Host

Write-Host "Report: $OutputFile" -ForegroundColor Green

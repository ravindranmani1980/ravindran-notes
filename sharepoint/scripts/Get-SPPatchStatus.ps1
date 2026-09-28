<#
.SYNOPSIS
    Verifies that every server in the farm is on the same SharePoint build after patching.

.DESCRIPTION
    For every SharePoint server in the farm, reports the file version of the core
    SharePoint DLL (Microsoft.SharePoint.dll), whether the server still needs upgrade,
    and the state of the SharePoint Timer and IIS services. Lists every database that
    still needs upgrading and gives an overall verdict.

    Read-only. Run from the SharePoint Management Shell (Windows PowerShell 5.1) as a
    farm administrator who is also a local administrator on the servers, because the
    DLL is read over the admin share (\\server\C$) and services are queried remotely.

    Tip: run it before patching and keep the output, then run it again afterwards.

.PARAMETER OutputFile
    CSV file for the per-server results.

.EXAMPLE
    .\Get-SPPatchStatus.ps1

.NOTES
    The farm build number is set by the highest update installed and configured. The
    DLL version normally matches it after a full update, but an individual update does
    not always change that DLL, so a small difference is flagged for checking rather
    than as a failure. Central Administration > Upgrade and Migration > Check product
    and patch installation status gives the authoritative per-server patch list.
#>
[CmdletBinding()]
param(
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('PatchStatus_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$farm      = Get-SPFarm
$farmBuild = $farm.BuildVersion
$hive      = $farmBuild.Major          # 14 = 2010, 15 = 2013, 16 = 2016/2019/SE
$dllPath   = "Program Files\Common Files\microsoft shared\Web Server Extensions\$hive\ISAPI\Microsoft.SharePoint.dll"

# SharePoint servers are the ones running the Timer service (this excludes SQL and mail servers)
$servers = Get-SPServer | Where-Object {
    $_.ServiceInstances | Where-Object { $_.GetType().Name -eq 'SPTimerServiceInstance' }
}

$rows = foreach ($server in $servers) {
    $name = $server.Address
    $isLocal = $name -ieq $env:COMPUTERNAME
    $file = if ($isLocal) { "C:\$dllPath" } else { "\\$name\C$\$dllPath" }

    $dllVersion = $null
    try { $dllVersion = [version](Get-Item -Path $file -ErrorAction Stop).VersionInfo.FileVersion }
    catch { $dllVersion = $null }

    $svcState = @{}
    foreach ($svc in 'SPTimerV4', 'W3SVC') {
        try {
            $s = if ($isLocal) { Get-Service -Name $svc -ErrorAction Stop } else { Get-Service -Name $svc -ComputerName $name -ErrorAction Stop }
            $svcState[$svc] = [string]$s.Status
        }
        catch { $svcState[$svc] = 'Unknown' }
    }

    $buildCheck = if (-not $dllVersion) { 'Could not read DLL' }
                  elseif ($dllVersion -eq $farmBuild) { 'Match' }
                  elseif ($dllVersion.Build -eq $farmBuild.Build) { 'Match (build)' }
                  else { 'Check' }

    [pscustomobject]@{
        Server       = $name
        Role         = $server.Role
        DllVersion   = if ($dllVersion) { $dllVersion.ToString() } else { '' }
        FarmBuild    = $farmBuild.ToString()
        BuildCheck   = $buildCheck
        NeedsUpgrade = $server.NeedsUpgrade
        TimerService = $svcState['SPTimerV4']
        IIS          = $svcState['W3SVC']
    }
}

$dbsBehind = @(Get-SPDatabase | Where-Object { $_.NeedsUpgrade } |
    Select-Object Name, @{n='Type';e={$_.TypeName}}, @{n='Server';e={$_.NormalizedDataSource}})

Write-Host "Farm build: $farmBuild   Farm needs upgrade: $($farm.NeedsUpgrade)" -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-Host

if ($dbsBehind.Count) {
    Write-Host 'Databases that still need upgrade:' -ForegroundColor Yellow
    $dbsBehind | Format-Table -AutoSize | Out-Host
}

$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$problems = @($rows | Where-Object { $_.NeedsUpgrade -or $_.BuildCheck -notlike 'Match*' -or $_.TimerService -ne 'Running' })
if (-not $farm.NeedsUpgrade -and $problems.Count -eq 0 -and $dbsBehind.Count -eq 0) {
    Write-Host 'Verdict: all servers and databases are on the farm build. Patching is complete.' -ForegroundColor Green
}
else {
    Write-Host "Verdict: needs attention ($($problems.Count) server(s), $($dbsBehind.Count) database(s)). Run Invoke-SPPostPatchConfig.ps1 on servers still needing upgrade." -ForegroundColor Yellow
}
Write-Host "Report: $OutputFile"

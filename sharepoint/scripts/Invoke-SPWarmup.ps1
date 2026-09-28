<#
.SYNOPSIS
    Warms up SharePoint web applications by requesting their pages after an app pool recycle.

.DESCRIPTION
    Requests the home page of every site collection (and optionally every subsite) in
    each web application, plus one application page per web application, so ASP.NET
    compiles and caches everything before users arrive. Logs the HTTP status and
    response time of every request.

    Run it on every web server, 10 to 15 minutes after the scheduled application pool
    recycle, as an account with read access to the sites. To warm the local server
    rather than whichever server the load balancer picks, add hosts file entries on
    each web server that point the site host names at that server's own IP address,
    and list those host names in the BackConnectionHostNames registry value.

    Read-only: it only sends GET requests.

.PARAMETER WebApplication
    One or more web application URLs. Default: every web application except Central Administration.

.PARAMETER IncludeSubsites
    Also request every subsite, not just site collection home pages.

.PARAMETER IncludeCentralAdmin
    Also warm up Central Administration.

.PARAMETER ExtraUrl
    Additional URLs to request, for example a search results page.

.PARAMETER TimeoutSec
    Timeout per request. Default 180 seconds (the first request after a recycle can be slow).

.PARAMETER LogFile
    CSV log of every request.

.EXAMPLE
    .\Invoke-SPWarmup.ps1

.EXAMPLE
    .\Invoke-SPWarmup.ps1 -WebApplication https://sharepoint.ravindran.in -IncludeSubsites -ExtraUrl https://sharepoint.ravindran.in/search/Pages/results.aspx?k=test -LogFile D:\Logs\Warmup.csv

.NOTES
    Schedule with Task Scheduler: program powershell.exe, arguments
    -NoProfile -ExecutionPolicy Bypass -File D:\Scripts\Invoke-SPWarmup.ps1 -LogFile D:\Logs\Warmup.csv
    Tick "Run whether user is logged on or not".
#>
[CmdletBinding()]
param(
    [string[]]$WebApplication,
    [switch]$IncludeSubsites,
    [switch]$IncludeCentralAdmin,
    [string[]]$ExtraUrl,
    [int]$TimeoutSec = 180,
    [string]$LogFile = (Join-Path -Path (Get-Location) -ChildPath ('Warmup_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

# _layouts/15 for 2013 and later; _layouts for 2010
$layouts = if ((Get-SPFarm).BuildVersion.Major -ge 15) { '_layouts/15' } else { '_layouts' }

$webApps = if ($WebApplication) { $WebApplication | ForEach-Object { Get-SPWebApplication -Identity $_ } }
           else { Get-SPWebApplication }
if ($IncludeCentralAdmin) {
    $webApps = @($webApps) + @(Get-SPWebApplication -IncludeCentralAdministration | Where-Object { $_.IsAdministrationWebApplication })
}

# Build the URL list
$urls = New-Object System.Collections.Generic.List[string]
foreach ($wa in $webApps) {
    $root = $wa.Url.TrimEnd('/')
    $urls.Add("$root/$layouts/viewlsts.aspx")
    foreach ($site in Get-SPSite -WebApplication $wa -Limit All) {
        try {
            if ($IncludeSubsites) {
                foreach ($web in $site.AllWebs) {
                    try { $urls.Add($web.Url) } finally { $web.Dispose() }
                }
            }
            else {
                $urls.Add($site.Url)
            }
        }
        finally { $site.Dispose() }
    }
}
foreach ($u in $ExtraUrl) { $urls.Add($u) }
$urls = $urls | Select-Object -Unique

Write-Host "Warming up $(@($urls).Count) URLs on $env:COMPUTERNAME..." -ForegroundColor Cyan
$log = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($url in $urls) {
    $i++
    Write-Progress -Activity 'Warming up' -Status $url -PercentComplete (($i / [math]::Max(@($urls).Count, 1)) * 100)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = $null; $message = ''
    try {
        $response = Invoke-WebRequest -Uri $url -UseDefaultCredentials -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $status = [int]$response.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $message = $_.Exception.Message
    }
    $timer.Stop()
    $log.Add([pscustomobject]@{
        Time    = Get-Date
        Server  = $env:COMPUTERNAME
        Url     = $url
        Status  = $status
        Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        Error   = $message
    })
}
Write-Progress -Activity 'Warming up' -Completed

$log | Export-Csv -Path $LogFile -NoTypeInformation -Encoding UTF8 -Append
$failed = @($log | Where-Object { $_.Status -ne 200 })
Write-Host ("Done. {0} URLs, {1} failed, slowest {2}s." -f $log.Count, $failed.Count, ($log | Measure-Object Seconds -Maximum).Maximum)
if ($failed.Count) { $failed | Select-Object Url, Status, Error | Format-Table -AutoSize -Wrap | Out-Host }
Write-Host "Log: $LogFile" -ForegroundColor Green

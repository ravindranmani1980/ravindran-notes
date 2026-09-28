<#
.SYNOPSIS
    Runs the SharePoint configuration step (PSConfig) on this server after installing an update.

.DESCRIPTION
    After an update's binaries are installed on every server in the farm, run this on
    each server, one server at a time, starting with the server that hosts Central
    Administration. It checks the session is elevated, shows whether this server needs
    upgrade, and runs PSConfig with the standard build-to-build upgrade command:

        PSConfig.exe -cmd upgrade -inplace b2b -wait -cmd applicationcontent -install
                     -cmd installfeatures -cmd secureresources -cmd services -install

    -UpgradeContentDatabases then upgrades any content database still marked as needing
    upgrade (use this on the last server, or on its own after all servers are done).

    Take the server out of the load balancer first if you're patching with zero downtime.

.PARAMETER UpgradeContentDatabases
    After PSConfig, run Upgrade-SPContentDatabase on every content database that still needs it.

.PARAMETER SkipPSConfig
    Don't run PSConfig; only upgrade content databases (use with -UpgradeContentDatabases).

.EXAMPLE
    .\Invoke-SPPostPatchConfig.ps1 -WhatIf

.EXAMPLE
    .\Invoke-SPPostPatchConfig.ps1

.EXAMPLE
    .\Invoke-SPPostPatchConfig.ps1 -SkipPSConfig -UpgradeContentDatabases

.NOTES
    PSConfig logs are written to the hive's LOGS folder (PSCDiagnostics_*.log and Upgrade-*.log).
    Verify the whole farm afterwards with Get-SPPatchStatus.ps1.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$UpgradeContentDatabases,
    [switch]$SkipPSConfig
)

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Run as administrator) SharePoint Management Shell.'
}

if (-not (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}

# Find PSConfig.exe in the newest installed hive
$psconfig = foreach ($hive in 16, 15, 14) {
    $candidate = Join-Path $env:CommonProgramFiles "microsoft shared\Web Server Extensions\$hive\BIN\psconfig.exe"
    if (Test-Path $candidate) { $candidate; break }
}
if (-not $psconfig) { throw 'PSConfig.exe was not found. Is SharePoint installed on this server?' }

try {
    $local = Get-SPServer -Identity $env:COMPUTERNAME -ErrorAction Stop
    Write-Host "Server $env:COMPUTERNAME  Role: $($local.Role)  Needs upgrade: $($local.NeedsUpgrade)" -ForegroundColor Cyan
    Write-Host "Farm build before: $((Get-SPFarm).BuildVersion)"
}
catch {
    Write-Warning "Could not read farm details ($($_.Exception.Message)). Continuing with PSConfig."
}

if (-not $SkipPSConfig) {
    $arguments = @('-cmd', 'upgrade', '-inplace', 'b2b', '-wait',
                   '-cmd', 'applicationcontent', '-install',
                   '-cmd', 'installfeatures',
                   '-cmd', 'secureresources',
                   '-cmd', 'services', '-install')

    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Run PSConfig b2b upgrade ($psconfig)")) {
        Write-Host 'Running PSConfig. This can take from a few minutes to an hour; do not close this window.' -ForegroundColor Cyan
        $started = Get-Date
        & $psconfig @arguments
        $exit = $LASTEXITCODE
        $minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        if ($exit -eq 0) {
            Write-Host "PSConfig completed successfully in $minutes minutes." -ForegroundColor Green
        }
        else {
            Write-Warning "PSConfig exited with code $exit after $minutes minutes. Check PSCDiagnostics_*.log and Upgrade-*.log in the LOGS folder before continuing."
            return
        }
    }
}

if ($UpgradeContentDatabases) {
    $behind = @(Get-SPContentDatabase | Where-Object { $_.NeedsUpgrade })
    if ($behind.Count -eq 0) {
        Write-Host 'No content databases need upgrade.' -ForegroundColor Green
    }
    foreach ($db in $behind) {
        if ($PSCmdlet.ShouldProcess($db.Name, 'Upgrade-SPContentDatabase')) {
            Write-Host "Upgrading $($db.Name)..." -ForegroundColor Cyan
            Upgrade-SPContentDatabase -Identity $db -Confirm:$false
        }
    }
}

try {
    Write-Host "Farm build now: $((Get-SPFarm).BuildVersion). Next: run this on the next server, then Get-SPPatchStatus.ps1." -ForegroundColor Cyan
} catch { }

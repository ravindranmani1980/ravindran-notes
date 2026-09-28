<#
.SYNOPSIS
    Tenant-wide SharePoint Online site inventory: storage, sharing, staleness, hubs.

.DESCRIPTION
    Connects to the SharePoint admin center with the SPO module and exports every site
    with its template, owner, storage, last content change, sharing setting, lock state
    and hub/group information. Sites with no content changes for -StaleDays are flagged.
    Read-only.

    Requires the SharePoint Administrator (or Global Administrator) role.

.PARAMETER AdminUrl
    SharePoint admin center URL, e.g. https://sharepointonline-admin.ravindran.in
    (on a standard tenant: https://<tenant>-admin.sharepoint.com).

.PARAMETER IncludeOneDrive
    Include OneDrive (personal) sites. These can be numerous in large tenants.

.PARAMETER StaleDays
    Days without content changes after which a site is flagged stale. Default 180.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPOSiteInventory.ps1 -AdminUrl https://sharepointonline-admin.ravindran.in

.EXAMPLE
    .\Get-SPOSiteInventory.ps1 -AdminUrl https://sharepointonline-admin.ravindran.in -IncludeOneDrive -StaleDays 365
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminUrl,
    [switch]$IncludeOneDrive,
    [int]$StaleDays = 180,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SPOSiteInventory_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    throw 'Module missing. Run: Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser'
}
Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking

Connect-SPOService -Url $AdminUrl

Write-Host 'Reading sites (this can take a while in large tenants)...' -ForegroundColor Cyan
$sites  = Get-SPOSite -Limit All -IncludePersonalSite $IncludeOneDrive.IsPresent
$cutoff = (Get-Date).AddDays(-$StaleDays)

$report = $sites | Select-Object Url, Title, Template, Owner,
    @{n='StorageUsedGB';     e={[math]::Round($_.StorageUsageCurrent / 1024, 2)}},
    @{n='StorageQuotaGB';    e={[math]::Round($_.StorageQuota / 1024, 2)}},
    LastContentModifiedDate,
    @{n='IsStale';           e={$_.LastContentModifiedDate -lt $cutoff}},
    SharingCapability,
    LockState,
    IsHubSite,
    @{n='IsGroupConnected';  e={$_.GroupId -and $_.GroupId -ne [guid]::Empty}}

$report | Sort-Object StorageUsedGB -Descending | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

# Short summary on screen
$totalGB = [math]::Round(($report | Measure-Object StorageUsedGB -Sum).Sum, 2)
[pscustomobject]@{
    Sites                 = @($report).Count
    TotalStorageGB        = $totalGB
    StaleSites            = @($report | Where-Object IsStale).Count
    AnyoneLinksAllowed    = @($report | Where-Object { $_.SharingCapability -eq 'ExternalUserAndGuestSharing' }).Count
    LockedSites           = @($report | Where-Object { $_.LockState -ne 'Unlock' }).Count
} | Format-List | Out-Host

Write-Host 'Largest 10 sites:' -ForegroundColor Cyan
$report | Sort-Object StorageUsedGB -Descending | Select-Object -First 10 Url, StorageUsedGB, LastContentModifiedDate | Format-Table -AutoSize | Out-Host

Write-Host "Report: $OutputFile" -ForegroundColor Green

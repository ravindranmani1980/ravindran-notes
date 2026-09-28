<#
.SYNOPSIS
    Lists guest (external) users on every SharePoint Online site that allows sharing.

.DESCRIPTION
    For each site where sharing is not disabled, reads the site's users with Get-SPOUser
    and keeps guest accounts (#ext# and email-share guest logins). Useful for quarterly
    access reviews and before archiving a site. Read-only.

    Get-SPOUser can return "Access denied" on sites where you are not a site collection
    admin. Those sites are listed in a separate "skipped" CSV so nothing is silently missed.

.PARAMETER AdminUrl
    SharePoint admin center URL, e.g. https://sharepointonline-admin.ravindran.in
    (on a standard tenant: https://<tenant>-admin.sharepoint.com).

.PARAMETER OutputFile
    CSV output path. A second file with the suffix _Skipped lists sites that could not be read.

.EXAMPLE
    .\Get-SPOExternalUsersReport.ps1 -AdminUrl https://sharepointonline-admin.ravindran.in
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminUrl,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SPOExternalUsers_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking -ErrorAction Stop
Connect-SPOService -Url $AdminUrl

$sites   = @(Get-SPOSite -Limit All | Where-Object { $_.SharingCapability -ne 'Disabled' })
$results = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($site in $sites) {
    $i++
    Write-Progress -Activity 'Checking sites for guests' -Status $site.Url -PercentComplete (($i / [math]::Max($sites.Count, 1)) * 100)
    try {
        $guests = Get-SPOUser -Site $site.Url -Limit All -ErrorAction Stop |
            Where-Object { $_.LoginName -like '*#ext#*' -or $_.LoginName -like '*urn%3aspo%3aguest*' }
    }
    catch {
        $skipped.Add([pscustomobject]@{ SiteUrl = $site.Url; Reason = $_.Exception.Message })
        continue
    }
    foreach ($g in $guests) {
        $results.Add([pscustomobject]@{
            SiteUrl           = $site.Url
            SiteTitle         = $site.Title
            SharingCapability = $site.SharingCapability
            DisplayName       = $g.DisplayName
            LoginName         = $g.LoginName
            IsSiteAdmin       = $g.IsSiteAdmin
            Groups            = ($g.Groups -join '; ')
        })
    }
}
Write-Progress -Activity 'Checking sites for guests' -Completed

$results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
if ($skipped.Count -gt 0) {
    $skippedFile = [IO.Path]::ChangeExtension($OutputFile, $null).TrimEnd('.') + '_Skipped.csv'
    $skipped | Export-Csv -Path $skippedFile -NoTypeInformation -Encoding UTF8
    Write-Warning "$($skipped.Count) site(s) could not be read. See $skippedFile"
}

Write-Host "Sites checked: $($sites.Count)  Guest entries: $($results.Count)  Unique guests: $(@($results | Select-Object -Unique LoginName).Count)"
Write-Host "Report: $OutputFile" -ForegroundColor Green

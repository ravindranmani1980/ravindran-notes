<#
.SYNOPSIS
    Checks SharePoint Online document libraries that hold GxP records against a baseline of library settings.

.DESCRIPTION
    For each site and document library, reports the settings that protect controlled
    documents and flags the ones that fall short of the baseline:
    - Versioning on, with at least -MinMajorVersions major versions kept
    - Minor (draft) versions on, and drafts visible only to people who can edit or approve
    - Require check out on
    - Content approval on (only flagged with -RequireApproval)
    - A default retention label on the library (only flagged with -RequireRetentionLabel)
    - Permission inheritance: libraries with unique permissions are listed for the access
      review

    SharePoint settings alone do not make a library Part 11 compliant: electronic signatures,
    review and approval workflows and record controls come from your procedures or from a
    validated document management add-on. Use this report to show the library settings your
    validation assumes are still in place.

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER SiteUrl
    Sites to check.

.PARAMETER LibraryName
    Libraries to check, by title. Default: every visible document library.

.PARAMETER ClientId
    Entra ID app (client) ID for PnP. Defaults to $env:PNP_CLIENT_ID.

.PARAMETER MinMajorVersions
    Minimum number of major versions to keep. Default 100.

.PARAMETER RequireApproval
    Flag libraries without content approval.

.PARAMETER RequireRetentionLabel
    Flag libraries without a default retention label.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPOGxPLibraryControls.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/qms

.EXAMPLE
    .\Get-SPOGxPLibraryControls.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/qms -LibraryName 'Controlled Documents' -RequireApproval -RequireRetentionLabel

.NOTES
    Requires PnP.PowerShell and your own Entra ID app (see
    https://notes.ravindran.in/sharepoint/guides/getting-started.html), and site collection
    admin or read access to library settings. Version history limits set at tenant or site
    level (automatic version trimming) can override the library's own numbers; check them in
    the SharePoint admin center.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$SiteUrl,
    [string[]]$LibraryName,
    [string]$ClientId = $env:PNP_CLIENT_ID,
    [ValidateRange(1, 50000)][int]$MinMajorVersions = 100,
    [switch]$RequireApproval,
    [switch]$RequireRetentionLabel,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SPOGxPLibraryControls_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not $ClientId) { throw 'Provide -ClientId or set $env:PNP_CLIENT_ID. See https://notes.ravindran.in/sharepoint/guides/getting-started.html' }

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters, [string]$RunAs)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# Signed in:  $RunAs"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

$labelCmd = @('Get-PnPRetentionLabel', 'Get-PnPLabel') | Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
$report = New-Object System.Collections.Generic.List[object]
$runAs = ''

foreach ($url in $SiteUrl) {
    Write-Host "Checking $url..." -ForegroundColor Cyan
    Connect-PnPOnline -Url $url -ClientId $ClientId -Interactive
    if (-not $runAs) { try { $runAs = (Get-PnPProperty -ClientObject (Get-PnPWeb) -Property CurrentUser).LoginName } catch { } }

    $lists = @(Get-PnPList -Includes EnableVersioning, EnableMinorVersions, MajorVersionLimit, MajorWithMinorVersionsLimit, ForceCheckout, EnableModeration, DraftVersionVisibility, HasUniqueRoleAssignments, IrmEnabled, RootFolder, BaseTemplate |
        Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden })
    if ($LibraryName) { $lists = @($lists | Where-Object { $LibraryName -contains $_.Title }) }

    foreach ($l in $lists) {
        $label = ''
        if ($labelCmd) {
            try { $lbl = & $labelCmd -List $l -ErrorAction Stop; $label = if ($lbl.TagName) { $lbl.TagName } elseif ($lbl.Name) { $lbl.Name } else { '' } } catch { }
        }

        $flags = New-Object System.Collections.Generic.List[string]
        if (-not $l.EnableVersioning) { $flags.Add('Versioning off') }
        elseif ($l.MajorVersionLimit -gt 0 -and $l.MajorVersionLimit -lt $MinMajorVersions) { $flags.Add("Keeps only $($l.MajorVersionLimit) major versions") }
        if (-not $l.EnableMinorVersions) { $flags.Add('Minor (draft) versions off') }
        elseif ([string]$l.DraftVersionVisibility -eq 'Reader') { $flags.Add('Drafts visible to all readers') }
        if (-not $l.ForceCheckout) { $flags.Add('Check out not required') }
        if ($RequireApproval -and -not $l.EnableModeration) { $flags.Add('Content approval off') }
        if ($RequireRetentionLabel -and -not $label) { $flags.Add('No default retention label') }

        $report.Add([pscustomobject]@{
            Site                   = $url
            Library                = $l.Title
            Url                    = $l.RootFolder.ServerRelativeUrl
            Versioning             = $l.EnableVersioning
            MajorVersionLimit      = $l.MajorVersionLimit
            MinorVersions          = $l.EnableMinorVersions
            DraftVisibility        = [string]$l.DraftVersionVisibility
            RequireCheckout        = $l.ForceCheckout
            ContentApproval        = $l.EnableModeration
            DefaultRetentionLabel  = $label
            UniquePermissions      = $l.HasUniqueRoleAssignments
            IrmEnabled             = $l.IrmEnabled
            ItemCount              = $l.ItemCount
            Flags                  = $flags -join '; '
        })
    }
}

if (-not $report.Count) { Write-Warning 'No document libraries found.'; return }

$report | Sort-Object @{e = { -not $_.Flags }}, Site, Library | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters -RunAs $runAs

$report | Select-Object Library, Versioning, MajorVersionLimit, RequireCheckout, ContentApproval, Flags | Format-Table -AutoSize -Wrap | Out-Host
Write-Host "Libraries: $($report.Count), with flags: $(@($report | Where-Object Flags).Count). Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

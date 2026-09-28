<#
.SYNOPSIS
    Reports where permission inheritance is broken in a SharePoint Online site.

.DESCRIPTION
    Exports the site's own permissions plus every list/library with unique permissions,
    and optionally every item/file/folder with unique permissions. Each row shows who has
    which permission level. "Limited Access" is filtered out because it is noise.

    Item-level scanning (-IncludeItems) calls the server once per item and can take a
    long time on big libraries. Run it on specific sites, not the whole tenant.

    Requires PnP.PowerShell and your own Entra ID app (see https://notes.ravindran.in/sharepoint/guides/getting-started.html).
    You need to be a site collection admin on the site.

.PARAMETER SiteUrl
    The site to scan.

.PARAMETER ClientId
    Entra ID app (client) ID for PnP. Defaults to $env:PNP_CLIENT_ID.

.PARAMETER IncludeItems
    Also check individual items, files and folders for unique permissions.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-SPOUniquePermissions.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/HR

.EXAMPLE
    .\Get-SPOUniquePermissions.ps1 -SiteUrl https://sharepointonline.ravindran.in/sites/HR -IncludeItems
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$ClientId = $env:PNP_CLIENT_ID,
    [switch]$IncludeItems,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('SPOUniquePermissions_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not $ClientId) { throw 'Provide -ClientId or set $env:PNP_CLIENT_ID. See https://notes.ravindran.in/sharepoint/guides/getting-started.html' }
Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive

$results = New-Object System.Collections.Generic.List[object]

function Add-PermissionRows {
    param(
        [Parameter(Mandatory)]$SecurableObject,
        [Parameter(Mandatory)][string]$ObjectType,
        [Parameter(Mandatory)][string]$Url
    )
    $assignments = Get-PnPProperty -ClientObject $SecurableObject -Property RoleAssignments
    foreach ($ra in $assignments) {
        Get-PnPProperty -ClientObject $ra -Property Member, RoleDefinitionBindings | Out-Null
        $levels = @($ra.RoleDefinitionBindings | Where-Object { $_.Name -ne 'Limited Access' } | ForEach-Object { $_.Name })
        if ($levels.Count -eq 0) { continue }
        $results.Add([pscustomobject]@{
            ObjectType    = $ObjectType
            Url           = $Url
            Principal     = $ra.Member.Title
            PrincipalType = $ra.Member.PrincipalType
            LoginName     = $ra.Member.LoginName
            Permissions   = $levels -join '; '
        })
    }
}

# 1. The site (web) itself
$web = Get-PnPWeb
Write-Host "Site: $($web.Url)" -ForegroundColor Cyan
Add-PermissionRows -SecurableObject $web -ObjectType 'Site' -Url $web.Url

# 2. Lists and libraries with unique permissions
$tenantRoot = ([uri]$web.Url).GetLeftPart([UriPartial]::Authority)
$lists = Get-PnPList -Includes HasUniqueRoleAssignments, RootFolder | Where-Object { -not $_.Hidden }

foreach ($list in $lists) {
    $listUrl = $tenantRoot + $list.RootFolder.ServerRelativeUrl
    if ($list.HasUniqueRoleAssignments) {
        Write-Host "  Unique: $($list.Title)" -ForegroundColor Yellow
        Add-PermissionRows -SecurableObject $list -ObjectType 'List' -Url $listUrl
    }

    # 3. Optional: items, files and folders
    if ($IncludeItems -and $list.ItemCount -gt 0) {
        Write-Host "  Scanning $($list.ItemCount) items in $($list.Title)..."
        $items = Get-PnPListItem -List $list -PageSize 500 -Fields FileRef, FileLeafRef, Title
        foreach ($item in $items) {
            $hasUnique = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments
            if (-not $hasUnique) { continue }
            $itemUrl = if ($item.FieldValues['FileRef']) { $tenantRoot + $item.FieldValues['FileRef'] } else { "$listUrl (ID $($item.Id))" }
            $type = switch ($item.FileSystemObjectType) { 'File' { 'File' } 'Folder' { 'Folder' } default { 'Item' } }
            Add-PermissionRows -SecurableObject $item -ObjectType $type -Url $itemUrl
        }
    }
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$results | Group-Object ObjectType | Select-Object Name, @{n='PermissionRows';e={$_.Count}} | Format-Table -AutoSize | Out-Host
Write-Host "Report: $OutputFile" -ForegroundColor Green

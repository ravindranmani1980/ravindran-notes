<#
.SYNOPSIS
    Builds a CSV inventory of a SharePoint Server farm.

.DESCRIPTION
    Collects the farm build number, servers, web applications, content databases,
    service applications, online service instances and farm solutions, and writes
    each set to its own CSV file. The script is read-only.

    Run it on a farm server from an elevated SharePoint Management Shell, as an
    account with SharePoint_Shell_Access (see Add-SPShellAdmin).

.PARAMETER OutputFolder
    Folder for the CSV files. Created if it does not exist.

.EXAMPLE
    .\Get-SPFarmInventory.ps1

.EXAMPLE
    .\Get-SPFarmInventory.ps1 -OutputFolder D:\Reports\Farm

.NOTES
    Written for SharePoint 2013 through Subscription Edition; most of it also works on 2010.
    Server Role values (MinRole) are only meaningful on 2016 and later.
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path -Path (Get-Location) -ChildPath ('FarmInventory_{0:yyyyMMdd_HHmm}' -f (Get-Date)))
)

# Load SharePoint cmdlets if they are not already available
if (-not (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

function Save-Report {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyCollection()][object[]]$Data
    )
    $file = Join-Path -Path $OutputFolder -ChildPath "$Name.csv"
    if ($Data) { $Data | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8 }
    Write-Host ('{0,-20} {1,6} rows  -> {2}' -f $Name, @($Data).Count, $file)
}

Write-Host "Collecting farm inventory..." -ForegroundColor Cyan

# Farm summary
$farm = Get-SPFarm
$configDb = Get-SPDatabase | Where-Object { $_.TypeName -like '*Configuration Database*' } | Select-Object -First 1
Save-Report -Name 'Farm' -Data @([pscustomobject]@{
    FarmBuild      = $farm.BuildVersion.ToString()
    ConfigDatabase = $configDb.Name
    ConfigDbServer = $configDb.NormalizedDataSource
    NeedsUpgrade   = $farm.NeedsUpgrade
    ServerCount    = @(Get-SPServer).Count
    ReportDate     = Get-Date
})

# Servers
Save-Report -Name 'Servers' -Data @(
    Get-SPServer | Select-Object @{n='Server';e={$_.Address}}, Role, Status, NeedsUpgrade
)

# Web applications, including Central Administration
Save-Report -Name 'WebApplications' -Data @(
    Get-SPWebApplication -IncludeCentralAdministration | Select-Object DisplayName, Url,
        @{n='AppPool';e={$_.ApplicationPool.Name}},
        @{n='AppPoolAccount';e={$_.ApplicationPool.Username}},
        @{n='ContentDatabases';e={$_.ContentDatabases.Count}},
        @{n='ListViewThreshold';e={$_.MaxItemsPerThrottledOperation}},
        @{n='AlternateUrls';e={($_.AlternateUrls | ForEach-Object { "$($_.UrlZone)=$($_.IncomingUrl)" }) -join '; '}}
)

# Content databases
Save-Report -Name 'ContentDatabases' -Data @(
    Get-SPContentDatabase | Select-Object Name,
        @{n='WebApplication';e={$_.WebApplication.Url}},
        @{n='SqlServer';e={$_.NormalizedDataSource}},
        @{n='SizeGB';e={[math]::Round($_.DiskSizeRequired / 1GB, 2)}},
        CurrentSiteCount, WarningSiteCount, MaximumSiteCount, Status, NeedsUpgrade
)

# Service applications
Save-Report -Name 'ServiceApplications' -Data @(
    Get-SPServiceApplication | Select-Object DisplayName, TypeName, Status,
        @{n='AppPool';e={$_.ApplicationPool.Name}}
)

# Which services run on which server
Save-Report -Name 'ServiceInstances' -Data @(
    Get-SPServiceInstance | Where-Object { $_.Status -eq 'Online' } |
        Select-Object @{n='Server';e={$_.Server.Address}}, TypeName, Status |
        Sort-Object Server, TypeName
)

# Farm solutions (WSPs) - important for upgrade and migration planning
Save-Report -Name 'Solutions' -Data @(
    Get-SPSolution | Select-Object Name, Deployed, DeploymentState, LastOperationResult,
        @{n='DeployedTo';e={($_.DeployedWebApplications | ForEach-Object { $_.Url }) -join '; '}}
)

Write-Host "Done. Reports saved to $OutputFolder" -ForegroundColor Green

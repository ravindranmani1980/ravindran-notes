<#
.SYNOPSIS
    Shows, enables, disables or flushes the BLOB cache for a web application.

.DESCRIPTION
    With no switch, shows the BlobCache setting in this server's web.config for every
    zone of the web application, and the size of the cache folder. This is read-only;
    run it on each web server to compare.

    -Enable and -Disable use SPWebConfigModification, so the setting is written to
    web.config on every web server in the farm (including servers added later) and for
    every zone, instead of editing each web.config by hand. A timer job applies the
    change within about a minute, and the application pool recycles.

    -Flush empties the BLOB cache for the web application on all its servers.

    Run from an elevated SharePoint Management Shell as a farm administrator.
    Guide: https://notes.ravindran.in/sharepoint/guides/blob-cache.html

.PARAMETER WebApplication
    The web application URL.

.PARAMETER Enable
    Turn the BLOB cache on with the settings below.

.PARAMETER Location
    Cache folder on each web server. Use a data drive, not C:. Default D:\BlobCache.

.PARAMETER MaxSizeGB
    Maximum cache size in GB, per server. Default 10.

.PARAMETER MaxAgeSeconds
    How long browsers may keep cached files before asking again. Default 86400 (24 hours).

.PARAMETER FileTypes
    Regular expression of file extensions to cache. Default: SharePoint's standard list.

.PARAMETER Disable
    Turn the BLOB cache off (sets enabled="false"; the other settings are kept).

.PARAMETER Flush
    Empty the BLOB cache for this web application on all servers.

.EXAMPLE
    .\Set-SPBlobCache.ps1 -WebApplication https://sharepoint.ravindran.in

.EXAMPLE
    .\Set-SPBlobCache.ps1 -WebApplication https://sharepoint.ravindran.in -Enable -Location D:\BlobCache -MaxSizeGB 10 -WhatIf

.EXAMPLE
    .\Set-SPBlobCache.ps1 -WebApplication https://sharepoint.ravindran.in -Enable -Location D:\BlobCache -MaxSizeGB 20 -MaxAgeSeconds 604800

.EXAMPLE
    .\Set-SPBlobCache.ps1 -WebApplication https://sharepoint.ravindran.in -Flush

.EXAMPLE
    .\Set-SPBlobCache.ps1 -WebApplication https://sharepoint.ravindran.in -Disable

.NOTES
    Works on SharePoint Server 2010 through Subscription Edition (not SharePoint Foundation).
    The SharePoint Timer Service must be running on every server for -Enable/-Disable to apply.
    Exclude the cache folder from antivirus real-time scanning.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Status')]
param(
    [Parameter(Mandatory)][string]$WebApplication,

    [Parameter(ParameterSetName = 'Enable', Mandatory)][switch]$Enable,
    [Parameter(ParameterSetName = 'Enable')][string]$Location = 'D:\BlobCache',
    [Parameter(ParameterSetName = 'Enable')][ValidateRange(1, 1000)][int]$MaxSizeGB = 10,
    [Parameter(ParameterSetName = 'Enable')][ValidateRange(0, 31536000)][int]$MaxAgeSeconds = 86400,
    [Parameter(ParameterSetName = 'Enable')][string]$FileTypes = '\.(gif|jpg|jpeg|jpe|jfif|bmp|dib|tif|tiff|themedbmp|themedcss|themedgif|themedjpg|themedpng|ico|png|wdp|hdp|css|js|asf|avi|flv|m4v|mov|mp3|mp4|mpeg|mpg|rm|rmvb|wma|wmv|ogg|ogv|oga|webm|xap)$',

    [Parameter(ParameterSetName = 'Disable', Mandatory)][switch]$Disable,

    [Parameter(ParameterSetName = 'Flush', Mandatory)][switch]$Flush
)

if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$wa = Get-SPWebApplication -Identity $WebApplication -ErrorAction Stop
$owner = 'BlobCacheSettings'   # marks the web.config entries this script manages

function New-BlobCacheAttribute {
    param([string]$Name, [string]$Value)
    $mod = New-Object Microsoft.SharePoint.Administration.SPWebConfigModification
    $mod.Path     = 'configuration/SharePoint/BlobCache'
    $mod.Name     = $Name
    $mod.Value    = $Value
    $mod.Sequence = 0
    $mod.Owner    = $owner
    $mod.Type     = [Microsoft.SharePoint.Administration.SPWebConfigModification+SPWebConfigModificationType]::EnsureAttribute
    $mod
}

function Set-BlobCacheAttributes {
    param([hashtable]$Attributes)
    # Replace only the attributes being set; leave any others this script set earlier
    $existing = @($wa.WebConfigModifications | Where-Object { $_.Owner -eq $owner -and $Attributes.ContainsKey($_.Name) })
    foreach ($m in $existing) { [void]$wa.WebConfigModifications.Remove($m) }
    foreach ($key in $Attributes.Keys) {
        $wa.WebConfigModifications.Add((New-BlobCacheAttribute -Name $key -Value $Attributes[$key]))
    }
    $wa.Update()
    $wa.Parent.ApplyWebConfigModifications()
}

switch ($PSCmdlet.ParameterSetName) {

    'Enable' {
        if ($Location -match '^[Cc]:') {
            Write-Warning 'The cache location is on the C: drive. A data drive is strongly recommended.'
        }
        $qualifier = Split-Path -Path $Location -Qualifier -ErrorAction SilentlyContinue
        if ($qualifier -and -not (Test-Path -Path "$qualifier\")) {
            Write-Warning "Drive $qualifier does not exist on this server. Make sure it exists on every web server."
        }
        $settings = @{
            'enabled'  = 'true'
            'location' = $Location
            'maxSize'  = "$MaxSizeGB"
            'max-age'  = "$MaxAgeSeconds"
            'path'     = $FileTypes
        }
        if ($PSCmdlet.ShouldProcess($wa.Url, "Enable BLOB cache at $Location ($MaxSizeGB GB, max-age $MaxAgeSeconds s) on all servers")) {
            Set-BlobCacheAttributes -Attributes $settings
            Write-Host "BLOB cache enabled for $($wa.Url). The timer job applies it to every server within about a minute." -ForegroundColor Green
            Write-Host 'Run this script without -Enable on each web server to confirm.'
        }
    }

    'Disable' {
        if ($PSCmdlet.ShouldProcess($wa.Url, 'Disable BLOB cache on all servers')) {
            Set-BlobCacheAttributes -Attributes @{ 'enabled' = 'false' }
            Write-Host "BLOB cache disabled for $($wa.Url). Delete the cache folders afterwards to free disk space." -ForegroundColor Green
        }
    }

    'Flush' {
        if ($PSCmdlet.ShouldProcess($wa.Url, 'Flush BLOB cache on all servers')) {
            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SharePoint.Publishing')
            [Microsoft.SharePoint.Publishing.PublishingCache]::FlushBlobCache($wa)
            Write-Host "BLOB cache flush requested for $($wa.Url)." -ForegroundColor Green
        }
    }

    'Status' {
        $rows = foreach ($zone in $wa.IisSettings.Keys) {
            $configFile = Join-Path -Path $wa.IisSettings[$zone].Path.FullName -ChildPath 'web.config'
            if (-not (Test-Path -Path $configFile)) {
                [pscustomobject]@{ Server = $env:COMPUTERNAME; Zone = $zone; Enabled = 'web.config not found on this server' }
                continue
            }
            $blob = ([xml](Get-Content -Path $configFile -Raw)).configuration.SharePoint.BlobCache
            $sizeGB = $null
            if ($blob.location -and (Test-Path -Path $blob.location)) {
                $bytes = (Get-ChildItem -Path $blob.location -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                $sizeGB = [math]::Round(([double]$bytes) / 1GB, 2)
            }
            [pscustomobject]@{
                Server        = $env:COMPUTERNAME
                Zone          = $zone
                Enabled       = $blob.enabled
                Location      = $blob.location
                MaxSizeGB     = $blob.maxSize
                MaxAgeSeconds = $blob.'max-age'
                CacheUsedGB   = $sizeGB
                WebConfig     = $configFile
            }
        }
        $rows | Format-List | Out-Host

        $managed = @($wa.WebConfigModifications | Where-Object { $_.Owner -eq $owner })
        if ($managed.Count -gt 0) {
            Write-Host 'Farm-wide settings applied by this script:' -ForegroundColor Cyan
            $managed | Select-Object Name, Value | Format-Table -AutoSize | Out-Host
        }
    }
}

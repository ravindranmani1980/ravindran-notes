<#
.SYNOPSIS
    Shows or sets the object cache super user and super reader accounts for a web application.

.DESCRIPTION
    The publishing object cache reads content as two dedicated accounts. Without them
    SharePoint logs event ID 7362 and caching is less effective. This script:
      - with only -WebApplication: shows the current accounts and matching user policies (read-only)
      - with -SuperUser and -SuperReader: adds Full Control and Full Read user policies for
        the accounts and stores them in the web application's properties

    Use two dedicated accounts that nobody signs in with, and that are not the app pool
    or farm account. Run iisreset on every web server afterwards and test immediately:
    wrong accounts can make publishing sites return "access denied" to everyone.

.PARAMETER WebApplication
    The web application URL.

.PARAMETER SuperUser
    Account for the Portal Super User, e.g. RAVINDRAN\sp-superuser.

.PARAMETER SuperReader
    Account for the Portal Super Reader, e.g. RAVINDRAN\sp-superreader.

.EXAMPLE
    .\Set-SPObjectCacheAccounts.ps1 -WebApplication https://sharepoint.ravindran.in

.EXAMPLE
    .\Set-SPObjectCacheAccounts.ps1 -WebApplication https://sharepoint.ravindran.in -SuperUser RAVINDRAN\sp-superuser -SuperReader RAVINDRAN\sp-superreader -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Show')]
param(
    [Parameter(Mandatory)][string]$WebApplication,
    [Parameter(ParameterSetName = 'Set', Mandatory)][string]$SuperUser,
    [Parameter(ParameterSetName = 'Set', Mandatory)][string]$SuperReader
)

if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-SPWebApplication -ErrorAction SilentlyContinue)) {
    throw 'SharePoint cmdlets are not available. Run this on a farm server from the SharePoint Management Shell.'
}

$wa = Get-SPWebApplication -Identity $WebApplication -ErrorAction Stop

function Show-Current {
    [pscustomobject]@{
        WebApplication = $wa.Url
        ClaimsAuth     = $wa.UseClaimsAuthentication
        SuperUser      = $wa.Properties['portalsuperuseraccount']
        SuperReader    = $wa.Properties['portalsuperreaderaccount']
    } | Format-List | Out-Host
    $wa.Policies | Where-Object { $_.DisplayName -in 'Portal Super User', 'Portal Super Reader' } |
        Select-Object DisplayName, UserName, @{n='Permission';e={($_.PolicyRoleBindings | ForEach-Object Name) -join ', '}} |
        Format-Table -AutoSize | Out-Host
}

if ($PSCmdlet.ParameterSetName -eq 'Show') {
    Show-Current
    return
}

if ($SuperUser -ieq $SuperReader) { throw 'Use two different accounts for the super user and the super reader.' }

# Claims web applications need the encoded claim, e.g. i:0#.w|ravindran\sp-superuser
function Resolve-Account([string]$Account) {
    if ($wa.UseClaimsAuthentication) {
        (New-SPClaimsPrincipal -Identity $Account -IdentityType WindowsSamAccountName).ToEncodedString()
    }
    else { $Account }
}
$su = Resolve-Account $SuperUser
$sr = Resolve-Account $SuperReader

function Add-Policy([string]$UserName, [string]$DisplayName, [Microsoft.SharePoint.Administration.SPPolicyRoleType]$RoleType) {
    $existing = $wa.Policies | Where-Object { $_.UserName -eq $UserName }
    $policy = if ($existing) { $existing } else { $wa.Policies.Add($UserName, $DisplayName) }
    $role = $wa.PolicyRoles.GetSpecialRole($RoleType)
    if (-not ($policy.PolicyRoleBindings | Where-Object { $_.Id -eq $role.Id })) {
        $policy.PolicyRoleBindings.Add($role)
    }
}

if ($PSCmdlet.ShouldProcess($wa.Url, "Set object cache accounts: super user $su, super reader $sr")) {
    Add-Policy -UserName $su -DisplayName 'Portal Super User'   -RoleType ([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl)
    Add-Policy -UserName $sr -DisplayName 'Portal Super Reader' -RoleType ([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullRead)
    $wa.Properties['portalsuperuseraccount']   = $su
    $wa.Properties['portalsuperreaderaccount'] = $sr
    $wa.Update()
    Show-Current
    Write-Host 'Done. Run iisreset on every web server, then browse your publishing sites to confirm they load.' -ForegroundColor Green
}

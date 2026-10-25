<#
.SYNOPSIS
    Builds a periodic access review worksheet for GxP-tagged Azure subscriptions and resource groups.

.DESCRIPTION
    Finds the GxP scope (subscriptions or resource groups tagged GxP = Yes, or the ones you
    name), lists every Azure role assignment that applies there, including ones inherited from
    management groups, and flags the rows a reviewer should look at first:
    - Privileged role: Owner, Contributor, User Access Administrator, RBAC Administrator
    - Direct user assignment: access given to a person instead of a group
    - Guest: an external (#EXT#) account
    - Principal deleted: the user, group or app no longer exists
    - Possible shared account: a user name that looks generic (admin, test, shared, svc...)
    - Custom role: check what it allows

    With -ExpandGroups, members of each assigned group are listed too, so the reviewer sees
    the people behind a group. With -IncludeEligible, PIM eligible assignments are added.

    The CSV has empty ReviewerDecision, ReviewerName and ReviewDate columns for sign-off.
    A .sha256 file is written next to it with the file hash, who ran it, when and with which
    parameters, so the export can be kept as review evidence.

    Read-only: it doesn't change anything.

.PARAMETER SubscriptionId
    Subscriptions to check. Default: every enabled subscription you can read.

.PARAMETER TagName
    Tag that marks GxP scope. Default GxP.

.PARAMETER TagValue
    Tag value that marks GxP scope. Default Yes.

.PARAMETER AllScopes
    Ignore the tag and treat every subscription checked as GxP scope.

.PARAMETER ExpandGroups
    Also list the direct members of each group that holds a role.

.PARAMETER IncludeEligible
    Also list PIM eligible role assignments (needs Az.Resources 6.0 or later).

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzGxPAccessReview.ps1

.EXAMPLE
    .\Get-AzGxPAccessReview.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ExpandGroups -IncludeEligible

.NOTES
    Requires Az.Accounts and Az.Resources, and Reader on the subscriptions. -ExpandGroups also
    needs permission to read groups in Microsoft Entra ID. Group members are one level deep:
    nested groups show as a group row, not as their members.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$TagName = 'GxP',
    [string]$TagValue = 'Yes',
    [switch]$AllScopes,
    [switch]$ExpandGroups,
    [switch]$IncludeEligible,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzGxPAccessReview_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# Signed in:  $((Get-AzContext).Account.Id)"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

function Get-TagValue($Tags, [string]$Name) {
    if (-not $Tags) { return $null }
    foreach ($k in $Tags.Keys) { if ($k -eq $Name) { return $Tags[$k] } }   # tag names are case-insensitive in Azure
    return $null
}

$privileged = @('Owner', 'Contributor', 'User Access Administrator', 'Role Based Access Control Administrator')
$sharedPattern = '(^|[._-])(admin|administrator|test|shared|generic|service|svc|temp|training|lab|qc|qa)\d*([._@-]|$)'

$subs = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' })
if ($SubscriptionId) { $subs = @($subs | Where-Object { $SubscriptionId -contains $_.Id }) }

$report = New-Object System.Collections.Generic.List[object]
$seen = @{}
$groupCache = @{}
$roleCache = @{}

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null

    # Work out the GxP scope in this subscription
    $scopes = @()
    $subTags = (Get-AzTag -ResourceId "/subscriptions/$($sub.Id)" -ErrorAction SilentlyContinue).Properties.TagsProperty
    if ($AllScopes -or (Get-TagValue $subTags $TagName) -eq $TagValue) {
        $scopes = @("/subscriptions/$($sub.Id)")
    } else {
        $scopes = @(Get-AzResourceGroup | Where-Object { (Get-TagValue $_.Tags $TagName) -eq $TagValue } | ForEach-Object { $_.ResourceId })
    }
    if (-not $scopes) { Write-Verbose "No GxP scope in $($sub.Name)"; continue }
    Write-Host "$($sub.Name): $($scopes.Count) GxP scope(s)" -ForegroundColor Cyan

    foreach ($scope in $scopes) {
        $rows = @(Get-AzRoleAssignment -Scope $scope | ForEach-Object { $_ | Add-Member -NotePropertyName AssignmentType -NotePropertyValue 'Active' -PassThru -Force })
        if ($IncludeEligible) {
            try {
                foreach ($e in @(Get-AzRoleEligibilitySchedule -Scope $scope -ErrorAction Stop)) {
                    $rows += [pscustomobject]@{
                        RoleAssignmentId   = $e.Id
                        Scope              = $e.Scope
                        RoleDefinitionName = $e.RoleDefinitionDisplayName
                        DisplayName        = $e.PrincipalDisplayName
                        SignInName         = $e.PrincipalEmail
                        ObjectType         = $e.PrincipalType
                        ObjectId           = $e.PrincipalId
                        AssignmentType     = 'Eligible (PIM)'
                    }
                }
            } catch { Write-Warning "Could not read PIM eligible assignments at $scope`: $($_.Exception.Message)" }
        }

        foreach ($ra in $rows) {
            $key = "$($ra.RoleAssignmentId)|$($ra.AssignmentType)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $flags = New-Object System.Collections.Generic.List[string]
            if ($privileged -contains $ra.RoleDefinitionName) { $flags.Add('Privileged role') }
            if ($ra.ObjectType -eq 'User') { $flags.Add('Direct user assignment') }
            if ($ra.SignInName -like '*#EXT#*') { $flags.Add('Guest') }
            if ($ra.ObjectType -eq 'Unknown' -or -not $ra.DisplayName) { $flags.Add('Principal deleted') }
            if ($ra.ObjectType -eq 'User' -and ("$($ra.SignInName) $($ra.DisplayName)" -match $sharedPattern)) { $flags.Add('Possible shared account') }
            if ($ra.RoleDefinitionName -and -not $roleCache.ContainsKey($ra.RoleDefinitionName)) {
                $roleCache[$ra.RoleDefinitionName] = Get-AzRoleDefinition -Name $ra.RoleDefinitionName -ErrorAction SilentlyContinue
            }
            if ($ra.RoleDefinitionName -and $roleCache[$ra.RoleDefinitionName].IsCustom) { $flags.Add('Custom role') }

            $scopeLevel = switch -Regex ($ra.Scope) {
                '^/providers/Microsoft.Management/managementGroups/' { 'Management group (inherited)'; break }
                '^/$'                                                { 'Root (inherited)'; break }
                '^/subscriptions/[^/]+$'                             { 'Subscription'; break }
                '^/subscriptions/[^/]+/resourceGroups/[^/]+$'        { 'Resource group'; break }
                default                                              { 'Resource' }
            }

            $base = [ordered]@{
                Subscription     = $sub.Name
                GxPScope         = $scope
                ScopeLevel       = $scopeLevel
                Scope            = $ra.Scope
                Role             = $ra.RoleDefinitionName
                AssignmentType   = $ra.AssignmentType
                Principal        = $ra.DisplayName
                SignInName       = $ra.SignInName
                ObjectType       = $ra.ObjectType
                ObjectId         = $ra.ObjectId
                ViaGroup         = ''
                Flags            = $flags -join '; '
                ReviewerDecision = ''
                ReviewerName     = ''
                ReviewDate       = ''
            }
            $report.Add([pscustomobject]$base)

            if ($ExpandGroups -and $ra.ObjectType -eq 'Group') {
                if (-not $groupCache.ContainsKey($ra.ObjectId)) {
                    try { $groupCache[$ra.ObjectId] = @(Get-AzADGroupMember -GroupObjectId $ra.ObjectId -ErrorAction Stop) }
                    catch { Write-Warning "Could not read members of $($ra.DisplayName): $($_.Exception.Message)"; $groupCache[$ra.ObjectId] = @() }
                }
                foreach ($m in $groupCache[$ra.ObjectId]) {
                    $type = ($m.OdataType -replace '^#microsoft.graph.', '')
                    $mFlags = New-Object System.Collections.Generic.List[string]
                    if ($privileged -contains $ra.RoleDefinitionName) { $mFlags.Add('Privileged role') }
                    if ($m.UserPrincipalName -like '*#EXT#*') { $mFlags.Add('Guest') }
                    if ($type -eq 'user' -and ("$($m.UserPrincipalName) $($m.DisplayName)" -match $sharedPattern)) { $mFlags.Add('Possible shared account') }
                    if ($type -eq 'group') { $mFlags.Add('Nested group: review its members') }
                    $row = [ordered]@{}
                    foreach ($k in $base.Keys) { $row[$k] = $base[$k] }
                    $row.Principal  = $m.DisplayName
                    $row.SignInName = $m.UserPrincipalName
                    $row.ObjectType = $type
                    $row.ObjectId   = $m.Id
                    $row.ViaGroup   = $ra.DisplayName
                    $row.Flags      = $mFlags -join '; '
                    $report.Add([pscustomobject]$row)
                }
            }
        }
    }
}

if (-not $report.Count) { Write-Warning "No GxP scope found. Tag subscriptions or resource groups $TagName = $TagValue, or use -AllScopes."; return }

$report | Sort-Object Subscription, GxPScope, Role, ViaGroup, Principal | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters

[pscustomobject]@{
    Rows                    = $report.Count
    PrivilegedRoles         = @($report | Where-Object { $_.Flags -like '*Privileged role*' -and -not $_.ViaGroup }).Count
    DirectUserAssignments   = @($report | Where-Object { $_.Flags -like '*Direct user assignment*' }).Count
    Guests                  = @($report | Where-Object { $_.Flags -like '*Guest*' }).Count
    PossibleSharedAccounts  = @($report | Where-Object { $_.Flags -like '*Possible shared account*' }).Count
    DeletedPrincipals       = @($report | Where-Object { $_.Flags -like '*Principal deleted*' }).Count
} | Format-List | Out-Host
Write-Host "Review worksheet: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

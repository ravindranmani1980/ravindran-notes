<#
.SYNOPSIS
    Reports Azure RBAC role assignments in every subscription and flags the risky ones.

.DESCRIPTION
    Lists every role assignment visible in each subscription (including resource group
    and resource scope) and flags:
    - Privileged roles: Owner, Contributor, User Access Administrator, Role Based Access Control Administrator
    - Guest (external) accounts
    - Roles granted directly to users rather than groups
    - Assignments whose principal no longer exists (ObjectType Unknown), left behind by deleted accounts

    Read-only. Use it for quarterly access reviews.

.PARAMETER SubscriptionId
    Limit the report to these subscription IDs. Default: every enabled subscription.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzRoleAssignmentReport.ps1

.EXAMPLE
    .\Get-AzRoleAssignmentReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.NOTES
    Requires Az.Accounts and Az.Resources, and Reader access (Microsoft.Authorization/roleAssignments/read).
    Clean up orphaned assignments with Remove-AzRoleAssignment -ObjectId <id> -RoleDefinitionName <role> -Scope <scope>.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzRoleAssignments_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

$privileged = @('Owner', 'Contributor', 'User Access Administrator', 'Role Based Access Control Administrator')
$subs = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' })
if ($SubscriptionId) { $subs = @($subs | Where-Object { $SubscriptionId -contains $_.Id }) }

$report = New-Object System.Collections.Generic.List[object]
foreach ($sub in $subs) {
    Write-Host "Reading $($sub.Name)..." -ForegroundColor Cyan
    Set-AzContext -Subscription $sub.Id | Out-Null
    foreach ($ra in Get-AzRoleAssignment) {
        $flags = New-Object System.Collections.Generic.List[string]
        if ($privileged -contains $ra.RoleDefinitionName) { $flags.Add('Privileged role') }
        if ($ra.ObjectType -eq 'Unknown') { $flags.Add('Principal deleted') }
        if ($ra.SignInName -like '*#EXT#*') { $flags.Add('Guest') }
        if ($ra.ObjectType -eq 'User') { $flags.Add('Direct user assignment') }

        $scopeLevel = switch -Regex ($ra.Scope) {
            '^/providers/Microsoft.Management/managementGroups/' { 'Management group (inherited)'; break }
            '^/$'                                                { 'Root (inherited)'; break }
            '^/subscriptions/[^/]+$'                             { 'Subscription'; break }
            '^/subscriptions/[^/]+/resourceGroups/[^/]+$'        { 'Resource group'; break }
            default                                              { 'Resource' }
        }

        $report.Add([pscustomobject]@{
            Subscription = $sub.Name
            ScopeLevel   = $scopeLevel
            Scope        = $ra.Scope
            Role         = $ra.RoleDefinitionName
            Principal    = $ra.DisplayName
            SignInName   = $ra.SignInName
            ObjectType   = $ra.ObjectType
            ObjectId     = $ra.ObjectId
            Flags        = $flags -join '; '
        })
    }
}

$report | Sort-Object Subscription, ScopeLevel, Role | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "Assignments: $($report.Count)" -ForegroundColor Cyan
[pscustomobject]@{
    PrivilegedRoles         = @($report | Where-Object { $_.Flags -like '*Privileged role*' }).Count
    PrivilegedDirectToUsers = @($report | Where-Object { $_.Flags -like '*Privileged role*' -and $_.ObjectType -eq 'User' }).Count
    Guests                  = @($report | Where-Object { $_.Flags -like '*Guest*' }).Count
    DeletedPrincipals       = @($report | Where-Object { $_.Flags -like '*Principal deleted*' }).Count
} | Format-List | Out-Host
Write-Host "Report: $OutputFile" -ForegroundColor Green

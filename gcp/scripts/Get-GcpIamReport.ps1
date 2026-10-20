<#
.SYNOPSIS
    Reports risky IAM grants and service account keys in every project: public access, basic roles, outside domains and user-managed keys.

.DESCRIPTION
    Reads each project's IAM policy and its service accounts' keys, and flags:
    - High: roles granted to allUsers or allAuthenticatedUsers
    - High: a default service account (Compute Engine or App Engine) with Owner or Editor
    - Medium: Owner or Editor granted to a user (use groups and predefined roles)
    - Medium: members from outside -AllowedDomain
    - Medium: Service Account User or Token Creator granted at project level (can act as every service account)
    - Medium: user-managed service account keys older than -KeyAgeDays
    - Low: Owner or Editor granted to a group; other user-managed keys; deleted principals still in the policy

    Read-only: it doesn't change any grants or keys.

.PARAMETER ProjectId
    Projects to report on. Default: every active project you can see.

.PARAMETER AllowedDomain
    Your own domains (for example ravindran.in). Members from any other domain are flagged. Default: not checked.

.PARAMETER KeyAgeDays
    Flag user-managed keys older than this. Default 90.

.PARAMETER SkipKeys
    Don't check service account keys (faster in projects with many service accounts).

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpIamReport.ps1 -AllowedDomain ravindran.in

.EXAMPLE
    .\Get-GcpIamReport.ps1 -ProjectId prj-notes-test -KeyAgeDays 30 -OutputFile .\iam.csv

.NOTES
    Requires the Google Cloud CLI (gcloud) and roles/iam.securityReviewer (or roles/viewer) on
    the projects. Only project-level grants are read: roles granted on the organisation or a
    folder also apply, so review those too (gcloud asset search-all-iam-policies does it in
    one call). Conditional grants are reported with their condition title.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [string[]]$AllowedDomain,
    [ValidateRange(1, 3650)][int]$KeyAgeDays = 90,
    [switch]$SkipKeys,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpIamReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { throw 'gcloud not found. Install the Google Cloud CLI and run gcloud auth login.' }

function Invoke-Gcloud {
    # Runs gcloud with JSON output and returns the result as objects. Throws on a gcloud error.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & gcloud @Arguments --format=json --quiet 2>&1
    $code = $LASTEXITCODE
    $text = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0) {
        $message = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        throw "gcloud $($Arguments[0..1] -join ' ') failed: $message"
    }
    if ($text) { foreach ($item in ($text | ConvertFrom-Json)) { $item } }
}

function Get-TargetProject {
    # The projects to report on: -ProjectId if given, otherwise every active project you can see
    param([string[]]$ProjectId)
    if ($ProjectId) { return $ProjectId }
    @(Invoke-Gcloud @('projects', 'list', '--filter=lifecycleState:ACTIVE') | ForEach-Object { $_.projectId })
}

function Get-Leaf {
    # Last part of a resource URL, for example the zone name from a zone URL
    param([string]$Url)
    if ($Url) { ($Url -split '/')[-1] } else { '' }
}

$report = New-Object System.Collections.Generic.List[object]
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2 }
$actAs = 'roles/iam.serviceAccountUser', 'roles/iam.serviceAccountTokenCreator'

function Add-Finding {
    param($Severity, $Finding, $Project, $Member, $Role, $Detail)
    $report.Add([pscustomobject]@{ Severity = $Severity; Finding = $Finding; Project = $Project; Member = $Member; Role = $Role; Detail = $Detail })
}

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan
    try {
        $policy = Invoke-Gcloud @('projects', 'get-iam-policy', $p)
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }

    foreach ($b in @($policy.bindings)) {
        if (-not $b) { continue }
        $role = $b.role
        $condition = if ($b.condition) { "condition: $($b.condition.title)" } else { '' }
        foreach ($m in @($b.members)) {
            $type, $id = $m -split ':', 2
            $domain = if ($id -match '@(.+)$') { $Matches[1].ToLower() } elseif ($type -eq 'domain') { $id.ToLower() } else { '' }

            if ($m -in 'allUsers', 'allAuthenticatedUsers') {
                Add-Finding 'High' 'Public grant' $p $m $role $condition
            }
            if ($type -eq 'serviceAccount' -and $role -in 'roles/owner', 'roles/editor' -and
                ($id -like '*-compute@developer.gserviceaccount.com' -or $id -like '*@appspot.gserviceaccount.com')) {
                Add-Finding 'High' 'Default service account with a basic role' $p $m $role $condition
            }
            if ($role -in 'roles/owner', 'roles/editor') {
                if ($type -eq 'user') { Add-Finding 'Medium' 'Basic role granted to a user' $p $m $role $condition }
                elseif ($type -eq 'group') { Add-Finding 'Low' 'Basic role granted to a group' $p $m $role $condition }
            }
            if ($role -in $actAs -and $type -in 'user', 'group', 'domain') {
                Add-Finding 'Medium' 'Can act as every service account in the project' $p $m $role $condition
            }
            if ($AllowedDomain -and $type -in 'user', 'group', 'domain' -and $domain -and
                -not ($AllowedDomain | Where-Object { $domain -eq $_.ToLower() -or $domain.EndsWith('.' + $_.ToLower()) })) {
                Add-Finding 'Medium' 'Member from outside your domains' $p $m $role $condition
            }
            if ($type -eq 'deleted') {
                Add-Finding 'Low' 'Deleted principal still in the policy' $p $m $role $condition
            }
        }
    }

    if ($SkipKeys) { continue }
    try {
        $accounts = @(Invoke-Gcloud @('iam', 'service-accounts', 'list', "--project=$p"))
    } catch {
        Write-Warning "Can't list service accounts in $p`: $($_.Exception.Message)"
        continue
    }
    foreach ($sa in $accounts) {
        foreach ($k in @(Invoke-Gcloud @('iam', 'service-accounts', 'keys', 'list', "--iam-account=$($sa.email)", '--managed-by=user', "--project=$p"))) {
            if (-not $k) { continue }
            $created = [datetime]::Parse($k.validAfterTime, [cultureinfo]::InvariantCulture)
            $age = [int]((Get-Date) - $created).TotalDays
            $detail = 'key {0}, created {1:yyyy-MM-dd}{2}' -f (Get-Leaf $k.name), $created, $(if ($k.disabled) { ', disabled' } else { '' })
            if ($age -gt $KeyAgeDays -and -not $k.disabled) {
                Add-Finding 'Medium' "User-managed key $age days old" $p "serviceAccount:$($sa.email)" '' $detail
            } else {
                Add-Finding 'Low' 'User-managed key' $p "serviceAccount:$($sa.email)" '' $detail
            }
        }
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Project, Finding, Member
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Findings: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

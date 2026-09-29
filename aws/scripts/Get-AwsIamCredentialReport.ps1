<#
.SYNOPSIS
    Reports IAM users and the root user from the IAM credential report, and flags the risky ones: no MFA, old or unused access keys.

.DESCRIPTION
    Generates the IAM credential report in each account and flags:
    - High: root user with access keys, or without MFA
    - High: IAM users with a console password and no MFA
    - Medium: root user signed in within the last -RootUsedDays days
    - Medium: active access keys older than -KeyAgeDays
    - Medium: active access keys not used for -UnusedDays days (or never)
    - Low: console passwords not used for -UnusedDays days (or never)

    Read-only: it doesn't change any users or keys.

.PARAMETER ProfileName
    AWS profiles to report on, one per account. Default: the current credentials.

.PARAMETER KeyAgeDays
    Flag active access keys older than this. Default 90.

.PARAMETER UnusedDays
    Flag passwords and active keys not used for this many days. Default 90.

.PARAMETER RootUsedDays
    Flag root user sign-ins within this many days. Default 30.

.PARAMETER IncludeAll
    Include every user, not only the ones with findings.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsIamCredentialReport.ps1

.EXAMPLE
    .\Get-AwsIamCredentialReport.ps1 -ProfileName notes-test, notes-prod -KeyAgeDays 60 -IncludeAll

.NOTES
    Requires AWS.Tools.IdentityManagement and AWS.Tools.SecurityToken, and the
    iam:GenerateCredentialReport and iam:GetCredentialReport permissions (included in
    SecurityAudit). The report is generated at most every four hours; a newer one is reused.
    People who sign in through IAM Identity Center don't appear here: they aren't IAM users.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [ValidateRange(1, 3650)][int]$KeyAgeDays = 90,
    [ValidateRange(1, 3650)][int]$UnusedDays = 90,
    [ValidateRange(1, 3650)][int]$RootUsedDays = 30,
    [switch]$IncludeAll,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsIamCredentialReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.IdentityManagement', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.IdentityManagement, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

# Credential report dates are ISO 8601 strings, or N/A, no_information, not_supported
function ConvertTo-Date {
    param([string]$Value)
    if ($Value -match '^\d{4}-\d{2}-\d{2}T') { return [datetime]::Parse($Value, [cultureinfo]::InvariantCulture).ToUniversalTime() }
    $null
}
function Get-Days {
    param($Date)
    if ($Date) { [int]((Get-Date).ToUniversalTime() - $Date).TotalDays } else { $null }
}

$report = New-Object System.Collections.Generic.List[object]
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{ Region = 'us-east-1' }
    if ($p) { $cred.ProfileName = $p }
    $account = (Get-STSCallerIdentity @cred).Account
    Write-Host "Account ${account}: generating the credential report..." -ForegroundColor Cyan

    $tries = 0
    do {
        $state = [string](Request-IAMCredentialReport @cred).State
        if ($state -ne 'COMPLETE') { Start-Sleep -Seconds 3 }
        $tries++
    } while ($state -ne 'COMPLETE' -and $tries -lt 20)
    if ($state -ne 'COMPLETE') { Write-Warning "Credential report not ready in $account; skipping."; continue }

    $rows = Get-IAMCredentialReport @cred -AsTextArray | ConvertFrom-Csv

    foreach ($u in $rows) {
        $isRoot = $u.user -eq '<root_account>'
        $findings = New-Object System.Collections.Generic.List[object]
        $passwordUsed = ConvertTo-Date $u.password_last_used
        $keys = foreach ($n in 1, 2) {
            if ($u."access_key_${n}_active" -eq 'true') {
                [pscustomobject]@{
                    Number   = $n
                    Rotated  = ConvertTo-Date $u."access_key_${n}_last_rotated"
                    LastUsed = ConvertTo-Date $u."access_key_${n}_last_used_date"
                }
            }
        }
        $keys = @($keys) | Where-Object { $_ }

        if ($isRoot) {
            if ($keys.Count) { $findings.Add(@('High', 'Root user has active access keys')) }
            if ($u.mfa_active -ne 'true') { $findings.Add(@('High', 'Root user without MFA')) }
            $rootDays = Get-Days $passwordUsed
            if ($null -ne $rootDays -and $rootDays -le $RootUsedDays) { $findings.Add(@('Medium', "Root user signed in $rootDays day(s) ago")) }
        } else {
            if ($u.password_enabled -eq 'true' -and $u.mfa_active -ne 'true') { $findings.Add(@('High', 'Console password without MFA')) }
            foreach ($k in $keys) {
                $age = Get-Days $k.Rotated
                if ($null -ne $age -and $age -gt $KeyAgeDays) { $findings.Add(@('Medium', "Access key $($k.Number) is $age days old")) }
                $idle = Get-Days $k.LastUsed
                if ($null -eq $idle) { $idle = Get-Days $k.Rotated; $findings.Add(@('Medium', "Access key $($k.Number) never used ($idle days since created)")) }
                elseif ($idle -gt $UnusedDays) { $findings.Add(@('Medium', "Access key $($k.Number) not used for $idle days")) }
            }
            if ($u.password_enabled -eq 'true') {
                $pwIdle = Get-Days $passwordUsed
                if ($null -eq $pwIdle) { $findings.Add(@('Low', 'Console password never used')) }
                elseif ($pwIdle -gt $UnusedDays) { $findings.Add(@('Low', "Console password not used for $pwIdle days")) }
            }
        }

        if (-not $findings.Count -and -not $IncludeAll) { continue }
        $top = ($findings | Sort-Object { $rank[$_[0]] } | Select-Object -First 1)
        $report.Add([pscustomobject]@{
            Account          = $account
            Severity         = if ($top) { $top[0] } else { '' }
            User             = $u.user
            Findings         = ($findings | ForEach-Object { $_[1] }) -join '; '
            ConsolePassword  = $u.password_enabled
            MFA              = $u.mfa_active
            PasswordLastUsed = $u.password_last_used
            ActiveKeys       = $keys.Count
            Created          = $u.user_creation_time
            Arn              = $u.arn
        })
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Account, User
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Users reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

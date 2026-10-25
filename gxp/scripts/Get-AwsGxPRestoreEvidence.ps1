<#
.SYNOPSIS
    Collects AWS Backup evidence for GxP accounts: vault lock, restore testing plans and restore jobs.

.DESCRIPTION
    For each account and region, writes one CSV with three kinds of row:
    - Vault: whether Vault Lock is on, its minimum and maximum retention, and the number of
      recovery points. Vaults without a lock are flagged.
    - TestingPlan: each AWS Backup restore testing plan, its schedule and when it last ran.
      A region with vaults but no restore testing plan is flagged.
    - Restore: each restore job in the last -Days days, including restore tests, with status,
      duration, validation result and whether it was started by a testing plan or by a person.
      This is the list to attach to restore test records.

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER Days
    How far back to look for restore jobs. Default 90.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsGxPRestoreEvidence.ps1 -ProfileName notes-gxp -Region us-east-1

.EXAMPLE
    .\Get-AwsGxPRestoreEvidence.ps1 -ProfileName notes-gxp -Days 365

.NOTES
    Requires AWS.Tools.Backup, AWS.Tools.EC2 and AWS.Tools.SecurityToken, and read access to
    AWS Backup. Restore testing plans need a recent AWS.Tools.Backup; with an older module
    the TestingPlan rows are skipped with a warning. AWS Backup keeps job history for a
    limited time, so export this report on a schedule if you need a longer record.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [ValidateRange(1, 365)][int]$Days = 90,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsGxPRestoreEvidence_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

$modules = @('AWS.Tools.Backup', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken')
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule $($modules -join ', ')" }
    Import-Module $m -ErrorAction Stop
}

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters, [string]$RunAs)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# AWS caller: $RunAs"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

function New-Row([string]$Account, [string]$Region, [string]$RecordType, [string]$Name) {
    [ordered]@{
        Account = $Account; Region = $Region; RecordType = $RecordType; Name = $Name
        Status = ''; ResourceType = ''; Detail = ''; Started = $null; Completed = $null; DurationMinutes = $null
        Validation = ''; StartedBy = ''; Flags = ''
    }
}

$hasTestingPlans = [bool](Get-Command -Name Get-BAKRestoreTestingPlanList -ErrorAction SilentlyContinue)
if (-not $hasTestingPlans) { Write-Warning 'This AWS.Tools.Backup version has no Get-BAKRestoreTestingPlanList: restore testing plans are skipped. Run Update-AWSToolsModule.' }

$report = New-Object System.Collections.Generic.List[object]
$callers = @()
$since = (Get-Date).AddDays(-$Days)
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $identity = Get-STSCallerIdentity @cred -Region $HomeRegion
    $account = $identity.Account
    $callers += $identity.Arn
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }

    foreach ($r in $regions) {
        $c = @{ Region = $r } + $cred
        try { $vaults = @(Get-BAKBackupVaultList @c -ErrorAction Stop) | Where-Object { $_ } }
        catch { Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"; continue }
        $vaults = @($vaults | Where-Object { $_.NumberOfRecoveryPoints -gt 0 -or $_.Locked })
        $restores = @(Get-BAKRestoreJobList @c -ByCreatedAfter $since) | Where-Object { $_ }
        if (-not $vaults -and -not $restores) { continue }
        Write-Host "Account $account, region $r..." -ForegroundColor Cyan

        foreach ($v in $vaults) {
            $row = New-Row $account $r 'Vault' $v.BackupVaultName
            $row.Status = if ($v.Locked) { 'Locked' } else { 'Not locked' }
            $row.Detail = "Recovery points: $($v.NumberOfRecoveryPoints); min retention: $($v.MinRetentionDays); max retention: $($v.MaxRetentionDays); lock date: $($v.LockDate)"
            if ($v.PSObject.Properties['VaultType'] -and $v.VaultType) { $row.ResourceType = [string]$v.VaultType }
            $flags = @()
            if (-not $v.Locked) { $flags += 'Vault Lock off' }
            elseif (-not $v.LockDate -or $v.LockDate -gt (Get-Date)) { $flags += 'Vault Lock in governance or grace period' }
            $row.Flags = $flags -join '; '
            $report.Add([pscustomobject]$row)
        }

        $plans = @()
        if ($hasTestingPlans) {
            try { $plans = @(Get-BAKRestoreTestingPlanList @c -ErrorAction Stop) | Where-Object { $_ } } catch { Write-Warning "Restore testing plans in $r`: $($_.Exception.Message)" }
            foreach ($pl in $plans) {
                $row = New-Row $account $r 'TestingPlan' $pl.RestoreTestingPlanName
                $row.Status = if ($pl.LastExecutionTime) { 'Has run' } else { 'Never run' }
                $row.Detail = "Schedule: $($pl.ScheduleExpression) $($pl.ScheduleExpressionTimezone)"
                $row.Started = $pl.LastExecutionTime
                if (-not $pl.LastExecutionTime -or $pl.LastExecutionTime -lt $since) { $row.Flags = "No run in $Days days" }
                $report.Add([pscustomobject]$row)
            }
            if ($vaults -and -not $plans) {
                $row = New-Row $account $r 'TestingPlan' '(none)'
                $row.Status = 'Missing'
                $row.Flags = 'Vaults hold recovery points but no restore testing plan exists'
                $report.Add([pscustomobject]$row)
            }
        }

        foreach ($j in $restores) {
            $row = New-Row $account $r 'Restore' $j.RestoreJobId
            $row.Status = [string]$j.Status
            $row.ResourceType = $j.ResourceType
            $row.Detail = "Recovery point: $($j.RecoveryPointArn); created: $($j.CreatedResourceArn)"
            $row.Started = $j.CreationDate
            $row.Completed = $j.CompletionDate
            $row.DurationMinutes = if ($j.CompletionDate -and $j.CreationDate) { [math]::Round(($j.CompletionDate - $j.CreationDate).TotalMinutes) } else { $null }
            if ($j.PSObject.Properties['ValidationStatus'] -and $j.ValidationStatus) { $row.Validation = "$($j.ValidationStatus) $($j.ValidationStatusMessage)".Trim() }
            $row.StartedBy = if ($j.CreatedBy -and $j.CreatedBy.RestoreTestingPlanArn) { 'Testing plan: ' + ($j.CreatedBy.RestoreTestingPlanArn -split ':')[-1] } else { 'Manual or other' }
            $flags = @()
            if ([string]$j.Status -notin 'COMPLETED', 'RUNNING', 'PENDING') { $flags += "Restore $($j.Status): $($j.StatusMessage)" }
            if ($row.Validation -match '^(FAILED|TIMED_OUT)') { $flags += 'Validation failed' }
            $row.Flags = $flags -join '; '
            $report.Add([pscustomobject]$row)
        }
    }
}

if (-not $report.Count) { Write-Warning 'No backup vaults with recovery points and no restore jobs were found.'; return }

$order = @{ 'Vault' = 0; 'TestingPlan' = 1; 'Restore' = 2 }
$report | Sort-Object Account, Region, @{e = { $order[$_.RecordType] }}, Started | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters -RunAs ($callers -join ', ')

[pscustomobject]@{
    Vaults            = @($report | Where-Object RecordType -eq 'Vault').Count
    VaultsNotLocked   = @($report | Where-Object { $_.RecordType -eq 'Vault' -and $_.Flags -like '*Vault Lock off*' }).Count
    TestingPlans      = @($report | Where-Object { $_.RecordType -eq 'TestingPlan' -and $_.Status -ne 'Missing' }).Count
    RestoreJobs       = @($report | Where-Object RecordType -eq 'Restore').Count
    RestoresCompleted = @($report | Where-Object { $_.RecordType -eq 'Restore' -and $_.Status -eq 'COMPLETED' }).Count
    RestoresWithFlags = @($report | Where-Object { $_.RecordType -eq 'Restore' -and $_.Flags }).Count
} | Format-List | Out-Host
Write-Host "Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

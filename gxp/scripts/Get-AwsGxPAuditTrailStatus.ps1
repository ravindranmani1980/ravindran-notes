<#
.SYNOPSIS
    Checks that CloudTrail and AWS Config give GxP accounts a complete, tamper-evident audit trail.

.DESCRIPTION
    For each account, checks the CloudTrail trails and, in each region, the AWS Config
    recorder, and writes one row per check with a Status of OK or Gap:
    - Multi-region trail logging: at least one multi-region trail is logging, and delivered
      recently (within -MaxDeliveryHours)
    - Log file validation: turned on, so changes to delivered log files can be detected
    - KMS encryption: trail logs encrypted with a KMS key
    - S3 versioning and S3 Object Lock on the trail bucket (reported as Not readable when the
      bucket is in another account, such as an organization log archive account)
    - CloudWatch Logs retention: at least -MinRetentionDays, if the trail sends to CloudWatch
    - Config recorder: recording in every region checked

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check for the Config recorder. Default: every region enabled in the account.

.PARAMETER MinRetentionDays
    Minimum CloudWatch Logs retention your procedures require. Default 365.

.PARAMETER MaxDeliveryHours
    A logging trail whose last delivery is older than this is a Gap. Default 24.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, CloudTrail, listing regions). Default us-east-1.

.PARAMETER GapsOnly
    Only list checks that are not OK.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsGxPAuditTrailStatus.ps1 -ProfileName notes-gxp

.EXAMPLE
    .\Get-AwsGxPAuditTrailStatus.ps1 -ProfileName notes-gxp, notes-prod -Region us-east-1, us-west-2 -GapsOnly

.NOTES
    Requires AWS.Tools.CloudTrail, AWS.Tools.S3, AWS.Tools.CloudWatchLogs,
    AWS.Tools.ConfigService, AWS.Tools.EC2 and AWS.Tools.SecurityToken, and read access
    (the SecurityAudit managed policy is enough). Organization trails are visible from member
    accounts, but their bucket usually is not: run it against the log archive account too.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [ValidateRange(1, 3653)][int]$MinRetentionDays = 365,
    [ValidateRange(1, 168)][int]$MaxDeliveryHours = 24,
    [string]$HomeRegion = 'us-east-1',
    [switch]$GapsOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsGxPAuditTrailStatus_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

$modules = @('AWS.Tools.CloudTrail', 'AWS.Tools.S3', 'AWS.Tools.CloudWatchLogs', 'AWS.Tools.ConfigService', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken')
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

$report = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Account, [string]$Region, [string]$Check, [string]$Resource, [bool]$Ok, [string]$Detail, [string]$Status) {
    if (-not $Status) { $Status = if ($Ok) { 'OK' } else { 'Gap' } }
    $report.Add([pscustomobject]@{ Account = $Account; Region = $Region; Check = $Check; Resource = $Resource; Status = $Status; Detail = $Detail })
}

$callers = @()
$targets = if ($ProfileName) { $ProfileName } else { @('') }
foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $identity = Get-STSCallerIdentity @cred -Region $HomeRegion
    $account = $identity.Account
    $callers += $identity.Arn
    Write-Host "Account $account..." -ForegroundColor Cyan

    # CloudTrail: trails are listed from any region, including organization trails and trails homed elsewhere
    $trails = @(Get-CTTrail @cred -Region $HomeRegion -IncludeShadowTrail $true) | Where-Object { $_ }
    $multiLogging = $false
    foreach ($t in $trails) {
        $tr = @{ Region = $t.HomeRegion } + $cred
        $name = if ($t.IsOrganizationTrail) { "$($t.Name) (organization trail)" } else { $t.Name }
        try { $st = Get-CTTrailStatus @tr -Name $t.TrailARN -ErrorAction Stop } catch { Add-Check $account $t.HomeRegion 'Trail status' $name $false $_.Exception.Message 'Not readable'; continue }

        $fresh = $st.LatestDeliveryTime -and $st.LatestDeliveryTime -gt (Get-Date).AddHours(-$MaxDeliveryHours)
        if ($t.IsMultiRegionTrail -and $st.IsLogging -and $fresh) { $multiLogging = $true }
        $detail = "Multi-region: $($t.IsMultiRegionTrail); logging: $($st.IsLogging); last delivery: $($st.LatestDeliveryTime)"
        if ($st.LatestDeliveryError) { $detail += "; delivery error: $($st.LatestDeliveryError)" }
        Add-Check $account $t.HomeRegion 'Trail logging' $name ([bool]($st.IsLogging -and $fresh)) $detail
        Add-Check $account $t.HomeRegion 'Log file validation' $name ([bool]$t.LogFileValidationEnabled) "LogFileValidationEnabled: $($t.LogFileValidationEnabled)"
        Add-Check $account $t.HomeRegion 'KMS encryption' $name ([bool]$t.KmsKeyId) $(if ($t.KmsKeyId) { $t.KmsKeyId } else { 'SSE-S3 only' })

        if ($t.S3BucketName) {
            $bucketRegion = $HomeRegion
            try {
                $loc = [string](Get-S3BucketLocation @cred -Region $HomeRegion -BucketName $t.S3BucketName -ErrorAction Stop).Value
                $bucketRegion = switch ($loc) { '' { 'us-east-1' } 'EU' { 'eu-west-1' } default { $loc } }
            } catch { }
            try {
                $v = Get-S3BucketVersioning @cred -Region $bucketRegion -BucketName $t.S3BucketName -ErrorAction Stop
                Add-Check $account $t.HomeRegion 'S3 versioning' $t.S3BucketName ([string]$v.Status -eq 'Enabled') "Versioning: $($v.Status)"
            } catch { Add-Check $account $t.HomeRegion 'S3 versioning' $t.S3BucketName $false $_.Exception.Message 'Not readable' }
            try {
                $ol = Get-S3ObjectLockConfiguration @cred -Region $bucketRegion -BucketName $t.S3BucketName -ErrorAction Stop
                $rule = $ol.Rule.DefaultRetention
                $d = "Object Lock: $($ol.ObjectLockEnabled)"
                if ($rule) { $d += "; default retention: $($rule.Mode) $($rule.Days)$($rule.Years) $(if ($rule.Days) { 'days' } elseif ($rule.Years) { 'years' })" }
                Add-Check $account $t.HomeRegion 'S3 Object Lock' $t.S3BucketName ([string]$ol.ObjectLockEnabled -eq 'Enabled') $d
            } catch {
                if ($_.Exception.Message -match 'ObjectLockConfigurationNotFound|does not exist') { Add-Check $account $t.HomeRegion 'S3 Object Lock' $t.S3BucketName $false 'Object Lock not configured' }
                else { Add-Check $account $t.HomeRegion 'S3 Object Lock' $t.S3BucketName $false $_.Exception.Message 'Not readable' }
            }
        }

        if ($t.CloudWatchLogsLogGroupArn) {
            $lgName = ($t.CloudWatchLogsLogGroupArn -split ':log-group:')[1] -replace ':\*$', ''
            try {
                $lg = @(Get-CWLLogGroup @tr -LogGroupNamePrefix $lgName -ErrorAction Stop) | Where-Object LogGroupName -eq $lgName | Select-Object -First 1
                $days = $lg.RetentionInDays
                $ok = (-not $days) -or $days -ge $MinRetentionDays   # no retention setting = kept forever
                Add-Check $account $t.HomeRegion 'CloudWatch Logs retention' $lgName $ok $(if ($days) { "$days days" } else { 'Never expire' })
            } catch { Add-Check $account $t.HomeRegion 'CloudWatch Logs retention' $lgName $false $_.Exception.Message 'Not readable' }
        }
    }
    Add-Check $account $HomeRegion 'Multi-region trail logging' $account $multiLogging $(if ($trails) { "$($trails.Count) trail(s) visible" } else { 'No trails' })

    # AWS Config recorder in each region
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }
    foreach ($r in $regions) {
        try {
            $rs = @(Get-CFGConfigurationRecorderStatus @cred -Region $r -ErrorAction Stop) | Where-Object { $_ }
            if (-not $rs) { Add-Check $account $r 'Config recorder' '(none)' $false 'No configuration recorder'; continue }
            foreach ($x in $rs) {
                Add-Check $account $r 'Config recorder' $x.Name ([bool]$x.Recording -and [string]$x.LastStatus -ne 'Failure') "Recording: $($x.Recording); last status: $($x.LastStatus) $($x.LastStatusChangeTime)"
            }
        } catch { Add-Check $account $r 'Config recorder' '' $false $_.Exception.Message 'Not readable' }
    }
}

$out = if ($GapsOnly) { @($report | Where-Object Status -ne 'OK') } else { $report }
$order = @{ 'Gap' = 0; 'Not readable' = 1; 'OK' = 2 }
$out | Sort-Object @{e = { $order[$_.Status] }}, Account, Check, Region | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters -RunAs ($callers -join ', ')

$report | Group-Object Check, Status | Select-Object @{n='Check, status';e={$_.Name}}, Count | Sort-Object 'Check, status' | Format-Table -AutoSize | Out-Host
Write-Host "Checks: $($report.Count), gaps: $(@($report | Where-Object Status -eq 'Gap').Count). Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

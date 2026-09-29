<#
.SYNOPSIS
    Shows which EC2 instances, RDS databases, DynamoDB tables and EFS file systems are protected by AWS Backup, and which aren't.

.DESCRIPTION
    For each account and region, compares the resources below with AWS Backup's list of
    protected resources, and reports each one as:
    - Protected: backed up within the last -StaleDays days
    - Stale: AWS Backup has a recovery point, but the latest is older than -StaleDays days
    - Not protected: no recovery point in AWS Backup
    Resource types: EC2 instances, RDS DB instances and Aurora clusters, DynamoDB tables
    and EFS file systems (use -ResourceType to choose).

    Read-only: it doesn't change anything.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER ResourceType
    Which resource types to check: EC2, RDS, DynamoDB, EFS. Default: all four.

.PARAMETER StaleDays
    A resource whose latest backup is older than this is Stale. Default 2.

.PARAMETER UnprotectedOnly
    Only list resources that are Stale or Not protected.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsBackupCoverage.ps1

.EXAMPLE
    .\Get-AwsBackupCoverage.ps1 -Region us-east-1 -ResourceType EC2, RDS -UnprotectedOnly

.NOTES
    Requires AWS.Tools.Backup, AWS.Tools.EC2 and AWS.Tools.SecurityToken, plus AWS.Tools.RDS,
    AWS.Tools.DynamoDBv2 and AWS.Tools.ElasticFileSystem for those types, and read access.
    Only AWS Backup is counted: RDS automated backups, DynamoDB point-in-time recovery and
    EBS snapshots taken by other tools aren't, so check those before acting on the report.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [ValidateSet('EC2', 'RDS', 'DynamoDB', 'EFS')][string[]]$ResourceType = @('EC2', 'RDS', 'DynamoDB', 'EFS'),
    [ValidateRange(1, 365)][int]$StaleDays = 2,
    [switch]$UnprotectedOnly,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsBackupCoverage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

$modules = @('AWS.Tools.Backup', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken')
if ($ResourceType -contains 'RDS') { $modules += 'AWS.Tools.RDS' }
if ($ResourceType -contains 'DynamoDB') { $modules += 'AWS.Tools.DynamoDBv2' }
if ($ResourceType -contains 'EFS') { $modules += 'AWS.Tools.ElasticFileSystem' }
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule $($modules -join ', ')" }
    Import-Module $m -ErrorAction Stop
}

$report = New-Object System.Collections.Generic.List[object]
$staleCutoff = (Get-Date).AddDays(-$StaleDays)
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $identity = Get-STSCallerIdentity @cred -Region $HomeRegion
    $account = $identity.Account
    $partition = ($identity.Arn -split ':')[1]
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }

    foreach ($r in $regions) {
        Write-Host "Account $account, region $r..." -ForegroundColor Cyan
        $c = @{ Region = $r } + $cred
        $protected = @{}
        try {
            foreach ($pr in @(Get-BAKProtectedResourceList @c -ErrorAction Stop) | Where-Object { $_ }) { $protected[$pr.ResourceArn] = $pr.LastBackupTime }
        } catch {
            Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"
            continue
        }

        # Each entry: Type, Name, Id, Arn, Owner
        $resources = New-Object System.Collections.Generic.List[object]
        if ($ResourceType -contains 'EC2') {
            foreach ($i in @((Get-EC2Instance @c).Instances) | Where-Object { $_ -and [string]$_.State.Name -notin 'terminated', 'shutting-down' }) {
                $resources.Add([pscustomobject]@{ Type = 'EC2'; Id = $i.InstanceId
                    Name = ($i.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1).Value
                    Owner = ($i.Tags | Where-Object Key -eq 'Owner' | Select-Object -First 1).Value
                    Arn = "arn:${partition}:ec2:${r}:${account}:instance/$($i.InstanceId)" })
            }
        }
        if ($ResourceType -contains 'RDS') {
            # Aurora is backed up per cluster, so skip instances that belong to a cluster
            foreach ($d in @(Get-RDSDBInstance @c) | Where-Object { $_ -and -not $_.DBClusterIdentifier }) {
                $resources.Add([pscustomobject]@{ Type = 'RDS'; Id = $d.DBInstanceIdentifier; Name = "$($d.Engine) $($d.DBInstanceClass)"
                    Owner = ($d.TagList | Where-Object Key -eq 'Owner' | Select-Object -First 1).Value; Arn = $d.DBInstanceArn })
            }
            foreach ($cl in @(Get-RDSDBCluster @c) | Where-Object { $_ }) {
                $resources.Add([pscustomobject]@{ Type = 'Aurora'; Id = $cl.DBClusterIdentifier; Name = $cl.Engine
                    Owner = ($cl.TagList | Where-Object Key -eq 'Owner' | Select-Object -First 1).Value; Arn = $cl.DBClusterArn })
            }
        }
        if ($ResourceType -contains 'DynamoDB') {
            foreach ($t in @(Get-DDBTableList @c) | Where-Object { $_ }) {
                $resources.Add([pscustomobject]@{ Type = 'DynamoDB'; Id = $t; Name = $t; Owner = ''
                    Arn = "arn:${partition}:dynamodb:${r}:${account}:table/$t" })
            }
        }
        if ($ResourceType -contains 'EFS') {
            foreach ($f in @(Get-EFSFileSystem @c) | Where-Object { $_ }) {
                $resources.Add([pscustomobject]@{ Type = 'EFS'; Id = $f.FileSystemId; Name = $f.Name
                    Owner = ($f.Tags | Where-Object Key -eq 'Owner' | Select-Object -First 1).Value; Arn = $f.FileSystemArn })
            }
        }

        foreach ($res in $resources) {
            $last = $protected[$res.Arn]
            $status = if (-not $protected.ContainsKey($res.Arn)) { 'Not protected' } elseif ($last -and $last -lt $staleCutoff) { 'Stale' } else { 'Protected' }
            if ($UnprotectedOnly -and $status -eq 'Protected') { continue }
            $report.Add([pscustomobject]@{
                Account    = $account
                Region     = $r
                Type       = $res.Type
                Id         = $res.Id
                Name       = $res.Name
                Status     = $status
                LastBackup = $last
                DaysSince  = if ($last) { [int]((Get-Date) - $last).TotalDays } else { $null }
                Owner      = $res.Owner
                Arn        = $res.Arn
            })
        }
    }
}

$order = @{ 'Not protected' = 0; 'Stale' = 1; 'Protected' = 2 }
$report | Sort-Object @{e = { $order[$_.Status] }}, Account, Region, Type, Id | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Type, Status | Select-Object @{n='Type, status';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Resources reported: $($report.Count). Report: $OutputFile" -ForegroundColor Green

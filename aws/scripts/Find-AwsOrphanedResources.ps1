<#
.SYNOPSIS
    Finds orphaned AWS resources that cost money or clutter: unattached EBS volumes, unused Elastic IPs, idle load balancers and more.

.DESCRIPTION
    Checks every enabled region in each account for:
    - EBS volumes that aren't attached to any instance
    - Elastic IP addresses not associated with anything
    - EBS snapshots older than -SnapshotAgeDays (and whether an AMI you own still uses them)
    - Application and Network Load Balancers with no registered targets
    - EC2 instances stopped for more than -StoppedDays days
    - Security groups not attached to any network interface (default groups excluded)

    Read-only: it doesn't delete anything. Review the list with the resource owners,
    then delete what's no longer needed.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER SnapshotAgeDays
    Report snapshots older than this many days. Default 90.

.PARAMETER StoppedDays
    Report instances stopped for longer than this many days. Default 30.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Find-AwsOrphanedResources.ps1

.EXAMPLE
    .\Find-AwsOrphanedResources.ps1 -ProfileName notes-test -Region us-east-1 -SnapshotAgeDays 30 -OutputFile .\orphans.csv

.NOTES
    Requires AWS.Tools.EC2, AWS.Tools.ElasticLoadBalancingV2 and AWS.Tools.SecurityToken, and
    read access. Some "orphans" are intentional (a volume kept after an instance was
    terminated, a reserved Elastic IP, a snapshot kept for compliance): check the tags and
    ask the owner before deleting.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [ValidateRange(1, 3650)][int]$SnapshotAgeDays = 90,
    [ValidateRange(1, 3650)][int]$StoppedDays = 30,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsOrphanedResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.EC2', 'AWS.Tools.ElasticLoadBalancingV2', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.EC2, AWS.Tools.ElasticLoadBalancingV2, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

function Get-TagValue {
    param($Tags, [string]$Key)
    ($Tags | Where-Object { $_.Key -eq $Key } | Select-Object -First 1).Value
}

$report = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param($Finding, $Account, $Region, $Id, $Name, $Detail, $Tags)
    $report.Add([pscustomobject]@{
        Finding = $Finding; Account = $Account; Region = $Region; Id = $Id; Name = $Name
        Detail = $Detail; Owner = (Get-TagValue $Tags 'Owner')
    })
}

$snapshotCutoff = (Get-Date).AddDays(-$SnapshotAgeDays)
$stoppedCutoff = (Get-Date).AddDays(-$StoppedDays)
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $account = (Get-STSCallerIdentity @cred -Region $HomeRegion).Account
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }

    foreach ($r in $regions) {
        Write-Host "Account $account, region $r..." -ForegroundColor Cyan
        $c = @{ Region = $r } + $cred
        try {
            $volumes = @(Get-EC2Volume @c -ErrorAction Stop) | Where-Object { $_ }
        } catch {
            Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"
            continue
        }

        # Unattached EBS volumes
        foreach ($v in $volumes | Where-Object { [string]$_.State -eq 'available' }) {
            Add-Finding 'Unattached EBS volume' $account $r $v.VolumeId (Get-TagValue $v.Tags 'Name') `
                ('{0}, {1} GB, created {2:yyyy-MM-dd}' -f $v.VolumeType, $v.Size, $v.CreateTime) $v.Tags
        }

        # Unassociated Elastic IPs
        foreach ($a in @(Get-EC2Address @c) | Where-Object { $_ -and -not $_.AssociationId }) {
            Add-Finding 'Unused Elastic IP' $account $r $a.AllocationId (Get-TagValue $a.Tags 'Name') $a.PublicIp $a.Tags
        }

        # Old snapshots, and whether an AMI you own still uses them
        $amiSnapshots = @{}
        foreach ($img in @(Get-EC2Image @c -Owner self) | Where-Object { $_ }) {
            foreach ($bdm in @($img.BlockDeviceMappings)) {
                if ($bdm -and $bdm.Ebs -and $bdm.Ebs.SnapshotId) { $amiSnapshots[$bdm.Ebs.SnapshotId] = $img.ImageId }
            }
        }
        foreach ($s in @(Get-EC2Snapshot @c -OwnerId self) | Where-Object { $_ -and $_.StartTime -lt $snapshotCutoff }) {
            $detail = '{0} GB, created {1:yyyy-MM-dd}' -f $s.VolumeSize, $s.StartTime
            if ($amiSnapshots[$s.SnapshotId]) { $detail += ", used by $($amiSnapshots[$s.SnapshotId])" }
            if ([string]$s.StorageTier -eq 'archive') { $detail += ', archive tier' }
            Add-Finding 'Old snapshot' $account $r $s.SnapshotId (Get-TagValue $s.Tags 'Name') $detail $s.Tags
        }

        # Load balancers with no registered targets
        foreach ($lb in @(Get-ELB2LoadBalancer @c) | Where-Object { $_ -and [string]$_.Type -ne 'gateway' }) {
            $targetCount = 0
            foreach ($tg in @(Get-ELB2TargetGroup @c -LoadBalancerArn $lb.LoadBalancerArn) | Where-Object { $_ }) {
                $targetCount += @(Get-ELB2TargetHealth @c -TargetGroupArn $tg.TargetGroupArn | Where-Object { $_ }).Count
            }
            if ($targetCount -eq 0) {
                Add-Finding 'Load balancer with no targets' $account $r $lb.LoadBalancerName $lb.DNSName `
                    ('{0}, {1}, created {2:yyyy-MM-dd}' -f $lb.Type, $lb.Scheme, $lb.CreatedTime) $null
            }
        }

        # Instances stopped for a long time (the stop date is in StateTransitionReason)
        $stopped = @((Get-EC2Instance @c -Filter @{ Name = 'instance-state-name'; Values = 'stopped' }).Instances) | Where-Object { $_ }
        foreach ($i in $stopped) {
            if ($i.StateTransitionReason -match '\((\d{4}-\d{2}-\d{2}) ') {
                $since = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
                if ($since -lt $stoppedCutoff) {
                    $gb = (@($volumes | Where-Object { $_.Attachments.InstanceId -contains $i.InstanceId }) | Measure-Object -Property Size -Sum).Sum
                    Add-Finding 'Long-stopped instance' $account $r $i.InstanceId (Get-TagValue $i.Tags 'Name') `
                        ('{0}, stopped since {1:yyyy-MM-dd}, {2} GB of EBS' -f $i.InstanceType, $since, [int]$gb) $i.Tags
                }
            }
        }

        # Security groups not attached to any network interface
        $inUse = @{}
        foreach ($eni in @(Get-EC2NetworkInterface @c) | Where-Object { $_ }) {
            foreach ($g in @($eni.Groups)) { if ($g) { $inUse[$g.GroupId] = $true } }
        }
        foreach ($sg in @(Get-EC2SecurityGroup @c) | Where-Object { $_ -and $_.GroupName -ne 'default' -and -not $inUse[$_.GroupId] }) {
            Add-Finding 'Unused security group' $account $r $sg.GroupId $sg.GroupName "$($sg.VpcId): $($sg.Description)" $sg.Tags
        }
    }
}

$report | Sort-Object Finding, Account, Region | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Finding | Select-Object @{n='Finding';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Findings: $($report.Count). Report: $OutputFile" -ForegroundColor Green

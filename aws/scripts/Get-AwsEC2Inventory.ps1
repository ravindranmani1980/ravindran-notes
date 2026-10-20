<#
.SYNOPSIS
    Lists every EC2 instance in every enabled region, with type, state, IPs, volumes, IMDS setting and tags.

.DESCRIPTION
    For each account (AWS profile) and region, lists every EC2 instance that isn't terminated:
    - Name tag, instance ID, type, state, platform and Availability Zone
    - Private and public IP addresses, VPC and subnet
    - Number and total size of attached EBS volumes
    - Whether IMDSv2 is required, and the instance profile (IAM role)
    - The Owner, CostCenter and Environment tags

    Read-only: it doesn't change anything.

.PARAMETER ProfileName
    AWS profiles to report on, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsEC2Inventory.ps1

.EXAMPLE
    .\Get-AwsEC2Inventory.ps1 -ProfileName notes-test, notes-prod -Region us-east-1, us-west-2 -OutputFile .\ec2.csv

.NOTES
    Requires AWS.Tools.EC2 and AWS.Tools.SecurityToken, and read access (for example the
    ReadOnlyAccess or ViewOnlyAccess permission set). Sign in first, for example with
    Invoke-AWSSSOLogin -ProfileName notes-test.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsEC2Inventory_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.EC2, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

function Get-TagValue {
    param($Tags, [string]$Key)
    ($Tags | Where-Object { $_.Key -eq $Key } | Select-Object -First 1).Value
}

$report = New-Object System.Collections.Generic.List[object]
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $account = (Get-STSCallerIdentity @cred -Region $HomeRegion).Account
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }

    foreach ($r in $regions) {
        Write-Host "Account $account, region $r..." -ForegroundColor Cyan
        try {
            $instances = @((Get-EC2Instance @cred -Region $r -ErrorAction Stop).Instances) | Where-Object { $_ }
        } catch {
            Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"
            continue
        }
        if (-not $instances) { continue }

        $volumes = @{}
        foreach ($v in @(Get-EC2Volume @cred -Region $r)) {
            if (-not $v) { continue }
            foreach ($a in @($v.Attachments)) {
                if (-not $a) { continue }
                if (-not $volumes[$a.InstanceId]) { $volumes[$a.InstanceId] = New-Object System.Collections.Generic.List[object] }
                $volumes[$a.InstanceId].Add($v)
            }
        }

        foreach ($i in $instances) {
            if ([string]$i.State.Name -eq 'terminated') { continue }
            $vols = if ($volumes.ContainsKey($i.InstanceId)) { $volumes[$i.InstanceId].ToArray() } else { @() }
            $report.Add([pscustomobject]@{
                Account         = $account
                Region          = $r
                Name            = Get-TagValue $i.Tags 'Name'
                InstanceId      = $i.InstanceId
                InstanceType    = [string]$i.InstanceType
                State           = [string]$i.State.Name
                Platform        = $i.PlatformDetails
                AvailabilityZone = $i.Placement.AvailabilityZone
                PrivateIp       = $i.PrivateIpAddress
                PublicIp        = $i.PublicIpAddress
                VpcId           = $i.VpcId
                SubnetId        = $i.SubnetId
                Volumes         = $vols.Count
                VolumeGB        = [int]($vols | Measure-Object -Property Size -Sum).Sum
                IMDSv2Required  = ([string]$i.MetadataOptions.HttpTokens -eq 'required')
                InstanceProfile = if ($i.IamInstanceProfile) { ($i.IamInstanceProfile.Arn -split '/')[-1] } else { '' }
                LaunchTime      = $i.LaunchTime
                Owner           = Get-TagValue $i.Tags 'Owner'
                CostCenter      = Get-TagValue $i.Tags 'CostCenter'
                Environment     = Get-TagValue $i.Tags 'Environment'
            })
        }
    }
}

$report | Sort-Object Account, Region, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Account, Region, State | Select-Object @{n='Account, region, state';e={$_.Name}}, Count |
    Format-Table -AutoSize | Out-Host
Write-Host "Instances: $($report.Count). Report: $OutputFile" -ForegroundColor Green

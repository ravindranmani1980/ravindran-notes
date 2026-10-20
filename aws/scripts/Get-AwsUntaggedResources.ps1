<#
.SYNOPSIS
    Lists AWS resources that are missing required tags, or have them spelled with the wrong case.

.DESCRIPTION
    For each account and region, reads resources through the Resource Groups Tagging API,
    and adds EC2 instances and EBS volumes (which can appear there only after they've been
    tagged once), then reports every resource where a -RequiredTag is:
    - missing, or
    - present with different capitalisation (AWS tag keys are case-sensitive, so
      costcenter and CostCenter are two different tags in cost reports)

    Read-only: it doesn't change any tags.

.PARAMETER RequiredTag
    Tag keys every resource must have. Default: Owner, CostCenter, Environment.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER ResourceType
    Limit the check to these resource types, in service:type form (for example ec2:instance, s3, rds:db). Default: all.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsUntaggedResources.ps1

.EXAMPLE
    .\Get-AwsUntaggedResources.ps1 -RequiredTag Owner, CostCenter -ResourceType ec2:instance, ec2:volume, rds:db -Region us-east-1

.NOTES
    Requires AWS.Tools.ResourceGroupsTaggingAPI, AWS.Tools.EC2 and AWS.Tools.SecurityToken, and
    read access. The Tagging API only lists resources that have, or once had, at least one
    tag, so a resource that was never tagged at all can be missing from the report (EC2
    instances and volumes are always checked). AWS Config's required-tags rule covers
    every resource type Config records.
#>
[CmdletBinding()]
param(
    [string[]]$RequiredTag = @('Owner', 'CostCenter', 'Environment'),
    [string[]]$ProfileName,
    [string[]]$Region,
    [string[]]$ResourceType,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsUntaggedResources_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.ResourceGroupsTaggingAPI', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.ResourceGroupsTaggingAPI, AWS.Tools.EC2, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

function Test-Wanted {
    param([string]$Type)
    if (-not $ResourceType) { return $true }
    foreach ($t in $ResourceType) { if ($Type -eq $t -or $Type -like "$t`:*") { return $true } }
    $false
}

$report = New-Object System.Collections.Generic.List[object]
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
        $resources = @{}   # ARN -> tag list

        try {
            foreach ($res in @(Get-RGTResource @c -ErrorAction Stop) | Where-Object { $_ }) { $resources[$res.ResourceARN] = @($res.Tags) }
        } catch {
            Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"
            continue
        }
        foreach ($i in @((Get-EC2Instance @c).Instances) | Where-Object { $_ -and [string]$_.State.Name -ne 'terminated' }) {
            $resources["arn:${partition}:ec2:${r}:${account}:instance/$($i.InstanceId)"] = @($i.Tags)
        }
        foreach ($v in @(Get-EC2Volume @c) | Where-Object { $_ }) {
            $resources["arn:${partition}:ec2:${r}:${account}:volume/$($v.VolumeId)"] = @($v.Tags)
        }

        foreach ($arn in $resources.Keys) {
            # arn:partition:service:region:account:resource-type/id  (or resource-type:id, or just id)
            $parts = $arn -split ':', 6
            $service = $parts[2]
            $resource = $parts[5]
            $subType = if ($resource -match '^([^/:]+)[/:]') { $Matches[1] } else { '' }
            $type = if ($subType) { "${service}:$subType" } else { $service }
            if (-not (Test-Wanted $type)) { continue }
            $tags = @($resources[$arn]) | Where-Object { $_ }
            $keys = @($tags | ForEach-Object { $_.Key })

            $missing = @(); $wrongCase = @()
            foreach ($t in $RequiredTag) {
                if ($keys -ccontains $t) { continue }
                $near = $keys | Where-Object { $_ -ieq $t } | Select-Object -First 1
                if ($near) { $wrongCase += "$near (should be $t)" } else { $missing += $t }
            }
            if (-not $missing -and -not $wrongCase) { continue }

            $report.Add([pscustomobject]@{
                Account      = $account
                Region       = $r
                ResourceType = $type
                Name         = ($tags | Where-Object Key -eq 'Name' | Select-Object -First 1).Value
                Missing      = $missing -join ', '
                WrongCase    = $wrongCase -join ', '
                Owner        = ($tags | Where-Object Key -eq 'Owner' | Select-Object -First 1).Value
                Arn          = $arn
            })
        }
    }
}

$report | Sort-Object Account, Region, ResourceType, Arn | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object @{n='Resource type';e={$_.Name}}, Count |
    Format-Table -AutoSize | Out-Host
Write-Host "Resources missing tags: $($report.Count). Report: $OutputFile" -ForegroundColor Green

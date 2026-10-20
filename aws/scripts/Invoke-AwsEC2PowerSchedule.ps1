<#
.SYNOPSIS
    Starts or stops EC2 instances that carry a schedule tag. Run it on a schedule from EC2, Lambda or Systems Manager.

.DESCRIPTION
    Finds instances with the tag -TagName set to -TagValue (default AutoShutdown = Yes) in the
    chosen regions and starts or stops them. Stopped instances aren't billed for compute, but
    their EBS volumes and any Elastic IPs still are. Instances already in the requested state
    are skipped, and so are instances in an Auto Scaling group (the group would replace them).

    Typical setup: a small EC2 instance or a scheduled Systems Manager Automation with a role
    allowed ec2:DescribeInstances, ec2:StartInstances and ec2:StopInstances, running the script
    at 19:00 (Stop) and 07:00 (Start) on weekdays. For large estates, the AWS Instance
    Scheduler solution does the same with more options.

    Supports -WhatIf.

.PARAMETER Action
    Start or Stop.

.PARAMETER TagName
    Tag that marks instances for scheduling. Default AutoShutdown.

.PARAMETER TagValue
    Tag value that opts an instance in. Default Yes.

.PARAMETER Region
    Regions to act on. Default: the default region of the current session.

.PARAMETER ProfileName
    AWS profile to use. Default: the current credentials (for example the instance profile).

.EXAMPLE
    .\Invoke-AwsEC2PowerSchedule.ps1 -Action Stop -WhatIf

.EXAMPLE
    .\Invoke-AwsEC2PowerSchedule.ps1 -Action Start -Region us-east-1, us-west-2 -ProfileName notes-test

.NOTES
    Requires AWS.Tools.EC2. The tag name and value are compared case-insensitively.
    Instances with encrypted volumes need the role to be allowed to use the KMS key to start.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
    [string]$TagName = 'AutoShutdown',
    [string]$TagValue = 'Yes',
    [string[]]$Region,
    [string]$ProfileName
)

if (-not (Get-Module -ListAvailable -Name AWS.Tools.EC2)) { throw 'AWS.Tools.EC2 not found. Run: Install-AWSToolsModule AWS.Tools.EC2' }
Import-Module AWS.Tools.EC2 -ErrorAction Stop

$cred = @{}
if ($ProfileName) { $cred.ProfileName = $ProfileName }
if (-not $Region) {
    $default = Get-DefaultAWSRegion
    if (-not $default) { throw 'No region given and no default region set. Use -Region, or Set-DefaultAWSRegion.' }
    $Region = @($default.Region)
}

$summary = New-Object System.Collections.Generic.List[object]

foreach ($r in $Region) {
    Write-Output "Region $r"
    $instances = @((Get-EC2Instance @cred -Region $r).Instances) | Where-Object {
        $_ -and ($_.Tags | Where-Object { $_.Key -ieq $TagName -and $_.Value -ieq $TagValue })
    }

    foreach ($i in $instances) {
        $name = ($i.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1).Value
        $state = [string]$i.State.Name
        $row = [pscustomobject]@{ Region = $r; InstanceId = $i.InstanceId; Name = $name; Before = $state; Result = '' }

        if ($i.Tags | Where-Object Key -eq 'aws:autoscaling:groupName') {
            $row.Result = 'Skipped (in an Auto Scaling group)'
        } elseif (($Action -eq 'Stop' -and $state -in 'stopped', 'stopping', 'terminated', 'shutting-down') -or
                  ($Action -eq 'Start' -and $state -in 'running', 'pending', 'terminated', 'shutting-down')) {
            $row.Result = 'Skipped (already in state)'
        } elseif ($PSCmdlet.ShouldProcess("$r/$($i.InstanceId) ($name)", "$Action instance")) {
            try {
                if ($Action -eq 'Stop') { Stop-EC2Instance @cred -Region $r -InstanceId $i.InstanceId -Force -ErrorAction Stop | Out-Null }
                else { Start-EC2Instance @cred -Region $r -InstanceId $i.InstanceId -ErrorAction Stop | Out-Null }
                $row.Result = 'Requested'
            } catch { $row.Result = "Failed: $($_.Exception.Message)" }
        } else { continue }
        $summary.Add($row)
    }
}

# Write-Output (not Write-Host) so the summary appears in job and Lambda logs
$summary | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ("{0}: {1} instance(s) acted on, {2} skipped, {3} failed." -f $Action,
    @($summary | Where-Object Result -eq 'Requested').Count,
    @($summary | Where-Object { $_.Result -like 'Skipped*' }).Count,
    @($summary | Where-Object { $_.Result -like 'Failed*' }).Count)

<#
.SYNOPSIS
    Reports security group rules in every region and flags the risky ones, such as SSH or RDP open to the internet.

.DESCRIPTION
    Reads the inbound rules of every security group in each account and region, and flags:
    - High: all traffic, or every port, allowed from the internet (0.0.0.0/0 or ::/0)
    - High: management ports (SSH, RDP, WinRM) or database ports allowed from the internet
    - Medium: other ports allowed from the internet (except -PublicPort, 80 and 443 by default)
    - Medium: a VPC's default security group that still has rules
    - Low: wide port ranges (more than -WidePortRange ports) allowed from an address range
    - Low: ICMP and other protocols without ports allowed from the internet
    Each row shows how many network interfaces use the group, so you can fix the rules
    that matter first.

    Read-only: it doesn't change any rules.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER RiskyPort
    Ports treated as management or database ports. Default: 22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 9200, 11211, 27017.

.PARAMETER PublicPort
    Ports that are expected to be open to the internet (on load balancers and web servers) and aren't flagged. Default: 80, 443.

.PARAMETER WidePortRange
    A rule allowing more ports than this in one range is flagged as wide. Default 100.

.PARAMETER IncludeAll
    Include every inbound rule, not only the flagged ones.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsSecurityGroupReport.ps1

.EXAMPLE
    .\Get-AwsSecurityGroupReport.ps1 -ProfileName notes-test -Region us-east-1 -IncludeAll -OutputFile .\sg-rules.csv

.EXAMPLE
    .\Get-AwsSecurityGroupReport.ps1 -PublicPort 443 -RiskyPort 22, 3389, 8080

.NOTES
    Requires AWS.Tools.EC2 and AWS.Tools.SecurityToken, and read access. A flagged rule on a
    group that no interface uses has no effect today, but will the moment someone attaches
    the group. Rules that reference other security groups or prefix lists are listed with
    -IncludeAll but never flagged as open to the internet.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [int[]]$RiskyPort = @(22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 9200, 11211, 27017),
    [int[]]$PublicPort = @(80, 443),
    [ValidateRange(1, 65535)][int]$WidePortRange = 100,
    [switch]$IncludeAll,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsSecurityGroupReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.EC2, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

function New-Row {
    param($Base, $Extra)
    $row = [ordered]@{}
    foreach ($k in $Base.Keys) { $row[$k] = $Base[$k] }
    foreach ($k in $Extra.Keys) { $row[$k] = $Extra[$k] }
    [pscustomobject]$row
}

$report = New-Object System.Collections.Generic.List[object]
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }
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
            $groups = @(Get-EC2SecurityGroup @c -ErrorAction Stop) | Where-Object { $_ }
        } catch {
            Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"
            continue
        }
        $attached = @{}
        foreach ($eni in @(Get-EC2NetworkInterface @c) | Where-Object { $_ }) {
            foreach ($g in @($eni.Groups)) { if ($g) { $attached[$g.GroupId] = 1 + [int]$attached[$g.GroupId] } }
        }

        foreach ($g in $groups) {
            $uses = [int]$attached[$g.GroupId]
            $base = [ordered]@{ Account = $account; Region = $r; GroupId = $g.GroupId; GroupName = $g.GroupName; VpcId = $g.VpcId; Interfaces = $uses }

            if ($g.GroupName -eq 'default' -and (@($g.IpPermissions | Where-Object { $_ }).Count -or @($g.IpPermissionsEgress | Where-Object { $_ }).Count)) {
                $report.Add((New-Row $base ([ordered]@{ Severity = 'Medium'; Finding = 'Default security group has rules (use named groups instead)';
                    Protocol = ''; Ports = ''; Source = ''; Description = '' })))
            }

            foreach ($perm in @($g.IpPermissions) | Where-Object { $_ }) {
                $proto = [string]$perm.IpProtocol
                $allTraffic = $proto -eq '-1'
                $from = if ($allTraffic -or $null -eq $perm.FromPort) { 0 } else { [int]$perm.FromPort }
                $to = if ($allTraffic -or $null -eq $perm.ToPort) { 65535 } else { [int]$perm.ToPort }
                $isPortProtocol = $allTraffic -or $proto -in 'tcp', 'udp', '6', '17'
                $ports = if ($allTraffic) { 'All' } elseif (-not $isPortProtocol) { "type $from" } elseif ($from -eq $to) { "$from" } else { "$from-$to" }
                $width = if ($isPortProtocol) { $to - $from + 1 } else { 0 }

                $sources = @()
                foreach ($x in @($perm.Ipv4Ranges) | Where-Object { $_ }) { $sources += [pscustomobject]@{ Value = $x.CidrIp; Cidr = $true; Description = $x.Description } }
                foreach ($x in @($perm.Ipv6Ranges) | Where-Object { $_ }) { $sources += [pscustomobject]@{ Value = $x.CidrIpv6; Cidr = $true; Description = $x.Description } }
                foreach ($x in @($perm.UserIdGroupPairs) | Where-Object { $_ }) { $sources += [pscustomobject]@{ Value = $x.GroupId; Cidr = $false; Description = $x.Description } }
                foreach ($x in @($perm.PrefixListIds) | Where-Object { $_ }) { $sources += [pscustomobject]@{ Value = $x.PrefixListId; Cidr = $false; Description = $x.Description } }

                foreach ($s in $sources) {
                    $fromInternet = $s.Value -in '0.0.0.0/0', '::/0'
                    $exposed = @($RiskyPort | Where-Object { $isPortProtocol -and $_ -ge $from -and $_ -le $to })
                    $expected = $isPortProtocol -and $from -eq $to -and $PublicPort -contains $from

                    $severity = ''; $finding = ''
                    if ($fromInternet -and ($allTraffic -or ($isPortProtocol -and $width -ge 65535))) {
                        $severity = 'High'; $finding = 'All traffic allowed from the internet'
                    } elseif ($fromInternet -and $exposed.Count) {
                        $severity = 'High'; $finding = "Management or database port open to the internet: $($exposed -join ', ')"
                    } elseif ($fromInternet -and -not $isPortProtocol) {
                        $severity = 'Low'; $finding = "Protocol $proto (for example ICMP) allowed from the internet"
                    } elseif ($fromInternet -and -not $expected) {
                        $severity = 'Medium'; $finding = 'Port open to the internet (check it should be public)'
                    } elseif ($s.Cidr -and $width -gt $WidePortRange) {
                        $severity = 'Low'; $finding = "Wide port range ($width ports)"
                    }
                    if (-not $severity -and -not $IncludeAll) { continue }

                    $report.Add((New-Row $base ([ordered]@{ Severity = $severity; Finding = $finding;
                        Protocol = if ($allTraffic) { 'All' } else { $proto }; Ports = $ports; Source = $s.Value; Description = $s.Description })))
                }
            }
        }
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Account, Region, GroupName
$report | Select-Object Severity, Finding, Account, Region, GroupId, GroupName, VpcId, Interfaces, Protocol, Ports, Source, Description |
    Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Rules reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

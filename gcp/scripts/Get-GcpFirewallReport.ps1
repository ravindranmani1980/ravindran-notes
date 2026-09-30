<#
.SYNOPSIS
    Reports VPC firewall rules in every project and flags the risky ones, such as SSH or RDP open to the internet.

.DESCRIPTION
    Reads the ingress allow rules of every VPC network in each project, and flags:
    - High: all protocols, or every port, allowed from the internet (0.0.0.0/0 or ::/0)
    - High: management ports (SSH, RDP, WinRM) or database ports allowed from the internet
    - Medium: other ports allowed from the internet (except -PublicPort, 80 and 443 by default)
    - Low: ICMP and other protocols without ports allowed from the internet
    - Low: wide port ranges (more than -WidePortRange ports) allowed from an address range
    - Low: disabled rules that would open ports to the internet if re-enabled
    Each row shows what the rule targets: "All instances" means every VM in the network,
    including ones created later.

    Read-only: it doesn't change any rules.

.PARAMETER ProjectId
    Projects to check. Default: every active project you can see.

.PARAMETER RiskyPort
    Ports treated as management or database ports. Default: 22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 9200, 11211, 27017.

.PARAMETER PublicPort
    Ports that are expected to be open to the internet (on web servers behind a load balancer) and aren't flagged. Default: 80, 443.

.PARAMETER WidePortRange
    A rule allowing more ports than this in one range is flagged as wide. Default 100.

.PARAMETER IncludeAll
    Include every ingress rule, not only the flagged ones.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpFirewallReport.ps1

.EXAMPLE
    .\Get-GcpFirewallReport.ps1 -ProjectId prj-notes-test -IncludeAll -OutputFile .\firewall.csv

.EXAMPLE
    .\Get-GcpFirewallReport.ps1 -PublicPort 443 -RiskyPort 22, 3389, 8080

.NOTES
    Requires the Google Cloud CLI (gcloud) and roles/compute.securityAdmin or roles/viewer on
    the projects. Covers VPC firewall rules only: rules in hierarchical and network firewall
    policies also apply, and are evaluated first or last depending on the network's
    enforcement order. For a Shared VPC, run it against the host project.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [int[]]$RiskyPort = @(22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 9200, 11211, 27017),
    [int[]]$PublicPort = @(80, 443),
    [ValidateRange(1, 65535)][int]$WidePortRange = 100,
    [switch]$IncludeAll,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpFirewallReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

# Returns @(low, high) for '443' or '1000-2000'
function Get-PortRange {
    param([string]$Port)
    if ($Port -match '^(\d+)-(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
    if ($Port -match '^\d+$') { return @([int]$Port, [int]$Port) }
    @(0, 65535)
}

$report = New-Object System.Collections.Generic.List[object]
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan
    try {
        $rules = @(Invoke-Gcloud @('compute', 'firewall-rules', 'list', "--project=$p", '--filter=direction=INGRESS'))
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }

    foreach ($r in $rules | Where-Object { $_ -and $_.allowed }) {
        $sources = @(@($r.sourceRanges) | Where-Object { $_ }) + @(@($r.sourceTags) | Where-Object { $_ } | ForEach-Object { "tag:$_" }) +
            @(@($r.sourceServiceAccounts) | Where-Object { $_ } | ForEach-Object { "sa:$_" })
        $fromInternet = [bool]($r.sourceRanges | Where-Object { $_ -in '0.0.0.0/0', '::/0' })
        $targets = @(@($r.targetTags) | Where-Object { $_ } | ForEach-Object { "tag:$_" }) +
            @(@($r.targetServiceAccounts) | Where-Object { $_ } | ForEach-Object { "sa:$_" })
        $targetText = if ($targets) { $targets -join ', ' } else { 'All instances' }

        foreach ($al in @($r.allowed)) {
            $proto = [string]$al.IPProtocol
            $allProtocols = $proto -eq 'all'
            $isPortProtocol = $allProtocols -or $proto -in 'tcp', 'udp', 'sctp', '6', '17', '132'
            $ranges = New-Object System.Collections.Generic.List[object]
            if ($allProtocols -or -not $al.ports) { $ranges.Add(@(0, 65535)) }
            else { foreach ($pt in @($al.ports)) { $ranges.Add((Get-PortRange $pt)) } }
            $portText = if ($allProtocols) { 'all' } elseif (-not $isPortProtocol) { $proto } elseif (-not $al.ports) { "$proto all ports" } else { "$proto " + ($al.ports -join ',') }
            $width = if ($isPortProtocol) { ($ranges | ForEach-Object { $_[1] - $_[0] + 1 } | Measure-Object -Maximum).Maximum } else { 0 }
            $exposed = @($RiskyPort | Where-Object { $port = $_; $isPortProtocol -and ($ranges | Where-Object { $port -ge $_[0] -and $port -le $_[1] }) })
            $onlyPublic = $isPortProtocol -and -not ($ranges | Where-Object { $_[0] -ne $_[1] -or $PublicPort -notcontains $_[0] })

            $severity = ''; $finding = ''
            if ($fromInternet -and ($allProtocols -or $width -ge 65536)) {
                $severity = 'High'; $finding = 'All traffic allowed from the internet'
            } elseif ($fromInternet -and $exposed.Count) {
                $severity = 'High'; $finding = "Management or database port open to the internet: $($exposed -join ', ')"
            } elseif ($fromInternet -and -not $isPortProtocol) {
                $severity = 'Low'; $finding = "Protocol $proto allowed from the internet"
            } elseif ($fromInternet -and -not $onlyPublic) {
                $severity = 'Medium'; $finding = 'Port open to the internet (check it should be public)'
            } elseif ($r.sourceRanges -and $width -gt $WidePortRange) {
                $severity = 'Low'; $finding = "Wide port range ($width ports)"
            }
            if ($r.disabled -and $severity) { $severity = 'Low'; $finding = "Disabled: $finding (if re-enabled)" }
            if (-not $severity -and -not $IncludeAll) { continue }

            $report.Add([pscustomobject]@{
                Severity = $severity
                Finding  = $finding
                Project  = $p
                Network  = Get-Leaf $r.network
                Rule     = $r.name
                Priority = $r.priority
                Allows   = $portText
                Sources  = $sources -join ', '
                Targets  = $targetText
                Logging  = [bool]$r.logConfig.enable
                Disabled = [bool]$r.disabled
            })
        }
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Project, Network, Priority
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Rules reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

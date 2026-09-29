<#
.SYNOPSIS
    Reports network security group rules in every subscription and flags the risky ones, such as RDP or SSH open to the internet.

.DESCRIPTION
    Uses Azure Resource Graph to read every custom inbound rule in every NSG you can see, and flags:
    - High: management ports (RDP, SSH, WinRM) or database ports allowed from the internet
    - High: any port allowed from the internet (destination port *)
    - Medium: other ports allowed from the internet
    - Medium: Any to Any allowed on every port, even inside the network
    - Low: wide port ranges (more than -WidePortRange ports) allowed from anywhere
    Each row shows whether the NSG is attached to anything, so you can fix the rules that matter first.

    Read-only: it doesn't change any rules.

.PARAMETER SubscriptionId
    Limit the report to these subscription IDs. Default: every subscription you can see.

.PARAMETER RiskyPort
    Ports treated as management or database ports. Default: 22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 27017.

.PARAMETER WidePortRange
    A rule allowing more ports than this in one range is flagged as wide. Default 100.

.PARAMETER IncludeAll
    Include every custom inbound rule, not only the flagged ones.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzNsgRuleReport.ps1

.EXAMPLE
    .\Get-AzNsgRuleReport.ps1 -IncludeAll -OutputFile .\nsg-rules.csv

.EXAMPLE
    .\Get-AzNsgRuleReport.ps1 -RiskyPort 22, 3389, 8080

.NOTES
    Requires Az.Accounts and Az.ResourceGraph, and Reader access. Only custom rules are
    checked; the default rules are the same everywhere. "From the internet" means a source
    of *, Any, Internet, 0.0.0.0/0 or ::/0. A flagged rule on an NSG that isn't attached
    to anything has no effect today, but will the moment someone attaches it.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [int[]]$RiskyPort = @(22, 23, 135, 139, 445, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6379, 27017),
    [ValidateRange(1, 65535)][int]$WidePortRange = 100,
    [switch]$IncludeAll,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzNsgRuleReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-Command Search-AzGraph -ErrorAction SilentlyContinue)) {
    throw 'Search-AzGraph not found. Run: Install-Module Az.ResourceGraph -Scope CurrentUser'
}
if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

function Invoke-GraphQuery {
    param([Parameter(Mandatory)][string]$Query)
    $results = New-Object System.Collections.Generic.List[object]
    $skipToken = $null
    do {
        $params = @{ Query = $Query; First = 1000 }
        if ($SubscriptionId) { $params.Subscription = $SubscriptionId } else { $params.UseTenantScope = $true }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $page = Search-AzGraph @params
        $rows = if ($page.PSObject.Properties['Data']) { $page.Data } else { $page }
        foreach ($r in $rows) { $results.Add($r) }
        $skipToken = $page.SkipToken
    } while ($skipToken)
    $results
}

# Single value and list properties both exist on a rule (sourceAddressPrefix / sourceAddressPrefixes); merge them
function Get-Values {
    param($Single, $Multiple)
    $values = @()
    if ($Single) { $values += [string]$Single }
    if ($Multiple) { $values += @($Multiple | ForEach-Object { [string]$_ }) }
    $values | Where-Object { $_ }
}

# Returns @(low, high) for '*', '443' or '1000-2000'
function Get-PortRange {
    param([string]$Port)
    if ($Port -eq '*') { return @(0, 65535) }
    if ($Port -match '^(\d+)-(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
    if ($Port -match '^\d+$') { return @([int]$Port, [int]$Port) }
    return @(-1, -1)
}

$anySource = @('*', 'any', 'internet', '0.0.0.0/0', '0.0.0.0', '::/0')

$subNames = @{}
foreach ($s in Invoke-GraphQuery "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, name") {
    $subNames[$s.subscriptionId] = $s.name
}

Write-Host 'Reading network security group rules...' -ForegroundColor Cyan
$rules = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| extend attachedSubnets = coalesce(array_length(properties.subnets), 0),
         attachedNics = coalesce(array_length(properties.networkInterfaces), 0)
| mv-expand rule = properties.securityRules
| where tostring(rule.properties.direction) =~ 'Inbound'
| project nsgName = name, resourceGroup, subscriptionId, location, attachedSubnets, attachedNics,
    ruleName = tostring(rule.name),
    priority = toint(rule.properties.priority),
    access = tostring(rule.properties.access),
    protocol = tostring(rule.properties.protocol),
    src = rule.properties.sourceAddressPrefix, srcList = rule.properties.sourceAddressPrefixes,
    srcAsg = rule.properties.sourceApplicationSecurityGroups,
    dst = rule.properties.destinationAddressPrefix, dstList = rule.properties.destinationAddressPrefixes,
    dstAsg = rule.properties.destinationApplicationSecurityGroups,
    port = rule.properties.destinationPortRange, portList = rule.properties.destinationPortRanges,
    nsgId = id
"@

$report = New-Object System.Collections.Generic.List[object]
foreach ($r in $rules) {
    $sources = @(Get-Values $r.src $r.srcList)
    if ($r.srcAsg) { $sources += @($r.srcAsg | ForEach-Object { 'ASG:' + ($_.id -split '/')[-1] }) }
    $destinations = @(Get-Values $r.dst $r.dstList)
    if ($r.dstAsg) { $destinations += @($r.dstAsg | ForEach-Object { 'ASG:' + ($_.id -split '/')[-1] }) }
    $ports = @(Get-Values $r.port $r.portList)

    $fromInternet = [bool]($sources | Where-Object { $anySource -contains $_.ToLower() })
    $toAnything = [bool]($destinations | Where-Object { @('*', 'any', 'virtualnetwork', '0.0.0.0/0') -contains $_.ToLower() })
    $allPorts = $ports -contains '*'

    $exposed = foreach ($p in $ports) {
        $range = Get-PortRange $p
        $RiskyPort | Where-Object { $_ -ge $range[0] -and $_ -le $range[1] }
    }
    $exposed = @($exposed | Sort-Object -Unique)
    $widest = ($ports | ForEach-Object { $x = Get-PortRange $_; $x[1] - $x[0] + 1 } | Measure-Object -Maximum).Maximum

    $severity = ''; $finding = ''
    if ($r.access -eq 'Allow') {
        if ($fromInternet -and $allPorts) {
            $severity = 'High'; $finding = 'Every port allowed from the internet'
        } elseif ($fromInternet -and $exposed.Count) {
            $severity = 'High'; $finding = "Management or database port allowed from the internet: $($exposed -join ', ')"
        } elseif ($fromInternet) {
            $severity = 'Medium'; $finding = 'Port allowed from the internet (check it should be public)'
        } elseif ($allPorts -and ($sources -contains '*' -or $sources -contains 'VirtualNetwork') -and $toAnything) {
            $severity = 'Medium'; $finding = 'Any to any on every port'
        } elseif ($widest -gt $WidePortRange -and ($sources -contains '*' -or $sources -contains 'VirtualNetwork')) {
            $severity = 'Low'; $finding = "Wide port range ($widest ports) allowed from anywhere in the network"
        }
    }
    if (-not $severity -and -not $IncludeAll) { continue }

    $attached = if ($r.attachedSubnets -or $r.attachedNics) { "$($r.attachedSubnets) subnet(s), $($r.attachedNics) NIC(s)" } else { 'Not attached' }
    $report.Add([pscustomobject]@{
        Severity      = $severity
        Finding       = $finding
        Subscription  = $subNames[$r.subscriptionId]
        ResourceGroup = $r.resourceGroup
        Nsg           = $r.nsgName
        AttachedTo    = $attached
        Rule          = $r.ruleName
        Priority      = $r.priority
        Access        = $r.access
        Protocol      = $r.protocol
        Source        = $sources -join ', '
        Destination   = $destinations -join ', '
        Ports         = $ports -join ', '
        NsgId         = $r.nsgId
    })
}

$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }
$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Subscription, Nsg, Priority
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity |
    Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Rules reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

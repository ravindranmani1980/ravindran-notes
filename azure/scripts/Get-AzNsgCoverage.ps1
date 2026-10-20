<#
.SYNOPSIS
    Finds gaps in network security group coverage: subnets and network interfaces with no NSG, and unused application security groups.

.DESCRIPTION
    Uses Azure Resource Graph to check every subscription you can see for:
    - High: network interfaces with a public IP and no NSG on either the NIC or its subnet
    - Medium: subnets with no NSG (subnets that don't support one, such as GatewaySubnet, are skipped)
    - Medium: VM network interfaces with no NSG on either the NIC or its subnet
    - Low: network interfaces with an NSG on both the NIC and the subnet (two layers to keep in step)
    - Low: application security groups with no members, or not used in any NSG rule

    Read-only: it doesn't change anything.

.PARAMETER SubscriptionId
    Limit the check to these subscription IDs. Default: every subscription you can see.

.PARAMETER SkipDualNsg
    Don't report network interfaces that have an NSG on both the NIC and the subnet.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzNsgCoverage.ps1

.EXAMPLE
    .\Get-AzNsgCoverage.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -SkipDualNsg

.NOTES
    Requires Az.Accounts and Az.ResourceGraph, and Reader access. A subnet with no NSG
    isn't always wrong (a subnet delegated to a service that manages its own filtering),
    but each one should have a reason. Pair it with Get-AzNsgRuleReport.ps1, which checks
    what the NSGs actually allow.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [switch]$SkipDualNsg,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzNsgCoverage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

# Subnets that don't take an NSG, or where the service manages the filtering
$exemptSubnets = @('GatewaySubnet', 'AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'RouteServerSubnet')

$subNames = @{}
foreach ($s in Invoke-GraphQuery "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, name") {
    $subNames[$s.subscriptionId] = $s.name
}

$report = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param($Severity, $Finding, $SubId, $ResourceGroup, $Name, $Detail, $ResourceId)
    $report.Add([pscustomobject]@{
        Severity      = $Severity
        Finding       = $Finding
        Subscription  = $subNames[$SubId]
        ResourceGroup = $ResourceGroup
        Name          = $Name
        Detail        = $Detail
        ResourceId    = $ResourceId
    })
}

Write-Host 'Reading subnets...' -ForegroundColor Cyan
$subnets = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets
| project vnetName = name, resourceGroup, subscriptionId,
    subnetId = tolower(tostring(subnet.id)),
    subnetName = tostring(subnet.name),
    prefix = tostring(coalesce(subnet.properties.addressPrefix, subnet.properties.addressPrefixes[0])),
    nsgId = tostring(subnet.properties.networkSecurityGroup.id),
    delegation = tostring(subnet.properties.delegations[0].properties.serviceName),
    ipConfigs = coalesce(array_length(subnet.properties.ipConfigurations), 0)
"@
$subnetNsg = @{}
foreach ($s in $subnets) {
    if (-not $s.subnetId) { continue }
    $subnetNsg[$s.subnetId] = $s.nsgId
    if ($s.nsgId -or $exemptSubnets -contains $s.subnetName) { continue }
    $detail = "$($s.vnetName) / $($s.prefix), $($s.ipConfigs) IP configuration(s)"
    if ($s.delegation) { $detail += ", delegated to $($s.delegation)" }
    if ($s.subnetName -eq 'AzureBastionSubnet') {
        Add-Finding 'Low' 'Bastion subnet with no NSG (optional, but recommended)' $s.subscriptionId $s.resourceGroup $s.subnetName $detail $s.subnetId
    } else {
        Add-Finding 'Medium' 'Subnet with no NSG' $s.subscriptionId $s.resourceGroup $s.subnetName $detail $s.subnetId
    }
}

Write-Host 'Reading network interfaces...' -ForegroundColor Cyan
$nics = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| project id, name, resourceGroup, subscriptionId,
    nsgId = tostring(properties.networkSecurityGroup.id),
    vmId = tostring(properties.virtualMachine.id),
    ipConfigs = properties.ipConfigurations
"@
$asgMembers = @{}
foreach ($n in $nics) {
    $hasPublicIp = $false
    $subnetHasNsg = $false
    foreach ($ic in @($n.ipConfigs)) {
        if (-not $ic) { continue }
        if ($ic.properties.publicIPAddress.id) { $hasPublicIp = $true }
        $sid = ([string]$ic.properties.subnet.id).ToLower()
        if ($sid -and $subnetNsg[$sid]) { $subnetHasNsg = $true }
        foreach ($asg in @($ic.properties.applicationSecurityGroups)) {
            if ($asg.id) { $asgMembers[([string]$asg.id).ToLower()] = $true }
        }
    }
    $vmName = if ($n.vmId) { ($n.vmId -split '/')[-1] } else { '' }
    $detail = if ($vmName) { "VM $vmName" } else { 'Not attached to a VM' }

    if (-not $n.nsgId -and -not $subnetHasNsg) {
        if ($hasPublicIp) {
            Add-Finding 'High' 'Public IP with no NSG on the NIC or subnet' $n.subscriptionId $n.resourceGroup $n.name $detail $n.id
        } elseif ($n.vmId) {
            Add-Finding 'Medium' 'VM network interface with no NSG on the NIC or subnet' $n.subscriptionId $n.resourceGroup $n.name $detail $n.id
        }
    } elseif ($n.nsgId -and $subnetHasNsg -and -not $SkipDualNsg) {
        Add-Finding 'Low' 'NSG on both the NIC and the subnet' $n.subscriptionId $n.resourceGroup $n.name "$detail; NIC NSG $(($n.nsgId -split '/')[-1])" $n.id
    }
}

Write-Host 'Reading application security groups...' -ForegroundColor Cyan
$asgUsed = @{}
$asgRefs = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| mv-expand rule = properties.securityRules
| mv-expand asg = array_concat(coalesce(rule.properties.sourceApplicationSecurityGroups, dynamic([])),
                               coalesce(rule.properties.destinationApplicationSecurityGroups, dynamic([])))
| where isnotempty(asg.id)
| distinct asgId = tolower(tostring(asg.id))
"@
foreach ($a in $asgRefs) { $asgUsed[$a.asgId] = $true }

$asgs = Invoke-GraphQuery "Resources | where type =~ 'microsoft.network/applicationsecuritygroups' | project id, name, resourceGroup, subscriptionId"
foreach ($a in $asgs) {
    $key = ([string]$a.id).ToLower()
    $problems = @()
    if (-not $asgMembers[$key]) { $problems += 'no members' }
    if (-not $asgUsed[$key]) { $problems += 'not used in any NSG rule' }
    if ($problems) {
        Add-Finding 'Low' 'Unused application security group' $a.subscriptionId $a.resourceGroup $a.name ($problems -join ', ') $a.id
    }
}

$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2 }
$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Finding, Subscription, ResourceGroup, Name
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Severity, Finding |
    Select-Object @{n='Finding';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Findings: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

<#
.SYNOPSIS
    Lists every Azure VM in every subscription you can see, with size, power state, disks, IPs and tags.

.DESCRIPTION
    Uses Azure Resource Graph, so it covers all subscriptions in seconds. For each VM
    it reports the subscription, resource group, location, zone, size, OS, power state,
    OS disk type, number of data disks, private IP addresses, Azure Hybrid Benefit
    license type and tags. Read-only.

    Watch the PowerState column: "stopped" (not "deallocated") means the VM is shut
    down but still billed for compute.

.PARAMETER SubscriptionId
    Limit the report to these subscription IDs. Default: every subscription you can see.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzVMInventory.ps1

.EXAMPLE
    .\Get-AzVMInventory.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.NOTES
    Requires Az.Accounts and Az.ResourceGraph, and Reader access. Sign in first with Connect-AzAccount.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzVMInventory_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

$subNames = @{}
foreach ($s in Invoke-GraphQuery "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, name") {
    $subNames[$s.subscriptionId] = $s.name
}

Write-Host 'Reading virtual machines...' -ForegroundColor Cyan
$vms = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project id, name, resourceGroup, subscriptionId, location, tags,
    zone        = tostring(zones[0]),
    size        = tostring(properties.hardwareProfile.vmSize),
    osType      = tostring(properties.storageProfile.osDisk.osType),
    osDiskType  = tostring(properties.storageProfile.osDisk.managedDisk.storageAccountType),
    dataDisks   = array_length(properties.storageProfile.dataDisks),
    powerState  = tostring(properties.extended.instanceView.powerState.code),
    licenseType = tostring(properties.licenseType),
    imageRef    = strcat(tostring(properties.storageProfile.imageReference.offer), ' ', tostring(properties.storageProfile.imageReference.sku))
"@

# Private IPs come from the network interfaces attached to each VM
$ipByVm = @{}
$nics = Invoke-GraphQuery @"
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isnotnull(properties.virtualMachine)
| mv-expand ipconfig = properties.ipConfigurations
| project vmId = tolower(tostring(properties.virtualMachine.id)), ip = tostring(ipconfig.properties.privateIPAddress)
"@
foreach ($n in $nics) {
    if (-not $ipByVm.ContainsKey($n.vmId)) { $ipByVm[$n.vmId] = New-Object System.Collections.Generic.List[string] }
    if ($n.ip) { $ipByVm[$n.vmId].Add($n.ip) }
}

$report = foreach ($vm in $vms) {
    $tagText = if ($vm.tags) { ($vm.tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ' } else { '' }
    $key = $vm.id.ToLower()
    [pscustomobject]@{
        Subscription  = $subNames[$vm.subscriptionId]
        ResourceGroup = $vm.resourceGroup
        Name          = $vm.name
        Location      = $vm.location
        Zone          = $vm.zone
        Size          = $vm.size
        OS            = $vm.osType
        Image         = "$($vm.imageRef)".Trim()
        PowerState    = ($vm.powerState -replace '^PowerState/', '')
        OsDiskType    = $vm.osDiskType
        DataDisks     = [int]$vm.dataDisks
        PrivateIPs    = if ($ipByVm.ContainsKey($key)) { $ipByVm[$key] -join ', ' } else { '' }
        HybridBenefit = if ($vm.licenseType) { $vm.licenseType } else { 'None' }
        Tags          = $tagText
    }
}

$report | Sort-Object Subscription, ResourceGroup, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "VMs: $(@($report).Count)" -ForegroundColor Cyan
$report | Group-Object PowerState | Select-Object @{n='PowerState';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
$stopped = @($report | Where-Object PowerState -eq 'stopped')
if ($stopped.Count) { Write-Warning "$($stopped.Count) VM(s) are stopped but NOT deallocated, so still billed for compute." }
Write-Host "Report: $OutputFile" -ForegroundColor Green

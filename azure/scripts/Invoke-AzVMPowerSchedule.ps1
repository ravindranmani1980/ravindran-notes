<#
.SYNOPSIS
    Starts or stops (deallocates) Azure VMs that carry a schedule tag. Designed for Azure Automation.

.DESCRIPTION
    Finds VMs with the tag -TagName set to -TagValue (default AutoShutdown = Yes) in the
    chosen subscriptions and starts or stops them. Stopping deallocates the VM, so it
    stops being billed for compute. VMs already in the requested state are skipped.

    Typical setup: an Azure Automation account with a system-assigned managed identity
    that has the Virtual Machine Contributor role on the subscriptions, and two
    schedules: Stop at 19:00 and Start at 07:00 on weekdays.

    Supports -WhatIf.

.PARAMETER Action
    Start or Stop.

.PARAMETER TagName
    Tag that marks VMs for scheduling. Default AutoShutdown.

.PARAMETER TagValue
    Tag value that opts a VM in. Default Yes.

.PARAMETER SubscriptionId
    Subscriptions to act on. Default: the current subscription only.

.PARAMETER UseManagedIdentity
    Sign in with the managed identity (use this in Azure Automation).

.PARAMETER NoWait
    Send the start/stop requests without waiting for each VM to finish.

.EXAMPLE
    .\Invoke-AzVMPowerSchedule.ps1 -Action Stop -WhatIf

.EXAMPLE
    .\Invoke-AzVMPowerSchedule.ps1 -Action Stop -UseManagedIdentity -SubscriptionId 00000000-0000-0000-0000-000000000000 -NoWait

.NOTES
    Requires Az.Accounts and Az.Compute. The tag name and value are compared case-insensitively.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
    [string]$TagName = 'AutoShutdown',
    [string]$TagValue = 'Yes',
    [string[]]$SubscriptionId,
    [switch]$UseManagedIdentity,
    [switch]$NoWait
)

if ($UseManagedIdentity) {
    Connect-AzAccount -Identity | Out-Null
}
$context = Get-AzContext
if (-not $context) { throw 'Not signed in. Run Connect-AzAccount, or use -UseManagedIdentity in Azure Automation.' }
if (-not $SubscriptionId) { $SubscriptionId = @($context.Subscription.Id) }

$summary = New-Object System.Collections.Generic.List[object]

foreach ($sub in $SubscriptionId) {
    Set-AzContext -Subscription $sub | Out-Null
    Write-Output "Subscription $sub"

    $vms = Get-AzVM -Status | Where-Object {
        $tags = $_.Tags
        if (-not $tags) { return $false }
        $key = $tags.Keys | Where-Object { $_ -ieq $TagName } | Select-Object -First 1
        $key -and ($tags[$key] -ieq $TagValue)
    }

    foreach ($vm in $vms) {
        $state = $vm.PowerState   # e.g. "VM running", "VM deallocated", "VM stopped"
        $needed = if ($Action -eq 'Stop') { $state -notmatch 'deallocated' } else { $state -notmatch 'running' }
        if (-not $needed) {
            $summary.Add([pscustomobject]@{ VM = $vm.Name; ResourceGroup = $vm.ResourceGroupName; Before = $state; Result = 'Skipped (already in state)' })
            continue
        }
        if ($PSCmdlet.ShouldProcess("$($vm.ResourceGroupName)/$($vm.Name)", "$Action VM")) {
            try {
                if ($Action -eq 'Stop') {
                    Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait:$NoWait -ErrorAction Stop | Out-Null
                }
                else {
                    Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait:$NoWait -ErrorAction Stop | Out-Null
                }
                $result = if ($NoWait) { 'Requested' } else { 'Done' }
            }
            catch { $result = "Failed: $($_.Exception.Message)" }
            $summary.Add([pscustomobject]@{ VM = $vm.Name; ResourceGroup = $vm.ResourceGroupName; Before = $state; Result = $result })
        }
    }
}

# Write-Output (not Write-Host) so the summary appears in Azure Automation job output
$summary | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ("{0}: {1} VM(s) acted on, {2} skipped, {3} failed." -f $Action,
    @($summary | Where-Object { $_.Result -in 'Done', 'Requested' }).Count,
    @($summary | Where-Object { $_.Result -like 'Skipped*' }).Count,
    @($summary | Where-Object { $_.Result -like 'Failed*' }).Count)

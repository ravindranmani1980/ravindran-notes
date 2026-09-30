<#
.SYNOPSIS
    Lists every Compute Engine VM in every project you can see, with machine type, status, IPs, disks, service account and labels.

.DESCRIPTION
    For each project, lists every VM instance:
    - Name, zone, machine type, status and provisioning model (standard or Spot)
    - Internal and external IP addresses
    - Number and total size of attached disks
    - The attached service account, and whether it's the Compute Engine default one
    - Shielded VM secure boot, and whether OS Login is set on the VM
    - The owner, costcenter and environment labels

    Read-only: it doesn't change anything.

.PARAMETER ProjectId
    Projects to report on. Default: every active project you can see.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpVMInventory.ps1

.EXAMPLE
    .\Get-GcpVMInventory.ps1 -ProjectId prj-notes-test, prj-payroll-prod -OutputFile .\vms.csv

.NOTES
    Requires the Google Cloud CLI (gcloud), signed in with gcloud auth login, and
    roles/compute.viewer (or roles/viewer) on the projects. Projects where the Compute Engine
    API isn't enabled are skipped with a warning. OS Login shows the VM's own metadata
    setting; it can also be set on the project or enforced by organisation policy.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpVMInventory_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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

$report = New-Object System.Collections.Generic.List[object]

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan
    try {
        $vms = @(Invoke-Gcloud @('compute', 'instances', 'list', "--project=$p"))
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }
    foreach ($vm in $vms) {
        $nic = @($vm.networkInterfaces)[0]
        $sa = [string](@($vm.serviceAccounts)[0].email)
        $osLogin = (@($vm.metadata.items) | Where-Object { $_.key -eq 'enable-oslogin' } | Select-Object -First 1).value
        $report.Add([pscustomobject]@{
            Project           = $p
            Name              = $vm.name
            Zone              = Get-Leaf $vm.zone
            MachineType       = Get-Leaf $vm.machineType
            Status            = $vm.status
            Provisioning      = if ($vm.scheduling.provisioningModel) { $vm.scheduling.provisioningModel } else { 'STANDARD' }
            InternalIp        = $nic.networkIP
            ExternalIp        = (@($nic.accessConfigs) | Where-Object { $_.natIP } | Select-Object -First 1).natIP
            Network           = Get-Leaf $nic.network
            Disks             = @($vm.disks).Count
            DiskGB            = [int](@($vm.disks) | ForEach-Object { [int]$_.diskSizeGb } | Measure-Object -Sum).Sum
            ServiceAccount    = $sa
            DefaultSA         = $sa -like '*-compute@developer.gserviceaccount.com'
            SecureBoot        = [bool]$vm.shieldedInstanceConfig.enableSecureBoot
            OsLogin           = if ($osLogin) { $osLogin } else { 'not set on VM' }
            Created           = $vm.creationTimestamp
            LastStart         = $vm.lastStartTimestamp
            Owner             = $vm.labels.owner
            CostCenter        = $vm.labels.costcenter
            Environment       = $vm.labels.environment
        })
    }
}

$report | Sort-Object Project, Name | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Group-Object Project, Status | Select-Object @{n='Project, status';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "VMs: $($report.Count). Report: $OutputFile" -ForegroundColor Green

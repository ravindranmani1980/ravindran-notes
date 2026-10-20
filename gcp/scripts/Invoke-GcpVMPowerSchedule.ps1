<#
.SYNOPSIS
    Starts or stops Compute Engine VMs that carry a schedule label. Run it on a schedule from Cloud Scheduler, a VM or a pipeline.

.DESCRIPTION
    Finds VMs with the label -LabelName set to -LabelValue (default autoshutdown = yes) in the
    chosen projects and starts or stops them. Stopped VMs aren't billed for vCPUs and memory,
    but their disks and any reserved IP addresses still are. VMs already in the requested
    state are skipped, and so are VMs in a managed instance group (the group would recreate
    or restart them; resize the group instead).

    Typical setup: a service account with roles/compute.instanceAdmin.v1 on the projects, and
    two scheduled runs: Stop at 19:00 and Start at 07:00 on weekdays. For a single project,
    Compute Engine instance schedules (a resource policy) do the same without a script.

    Supports -WhatIf.

.PARAMETER Action
    Start or Stop.

.PARAMETER LabelName
    Label that marks VMs for scheduling. Default autoshutdown.

.PARAMETER LabelValue
    Label value that opts a VM in. Default yes.

.PARAMETER ProjectId
    Projects to act on. Default: the current gcloud project only.

.PARAMETER Wait
    Wait for each start or stop to finish, instead of sending the requests and moving on.

.EXAMPLE
    .\Invoke-GcpVMPowerSchedule.ps1 -Action Stop -WhatIf

.EXAMPLE
    .\Invoke-GcpVMPowerSchedule.ps1 -Action Start -ProjectId prj-notes-test, prj-payroll-test

.NOTES
    Requires the Google Cloud CLI (gcloud) and roles/compute.instanceAdmin.v1 (or a custom role
    with compute.instances.list, start and stop) on the projects. Label values are lowercase
    in Google Cloud; the comparison is case-insensitive anyway. Spot VMs can be stopped by
    Google at any time regardless of this schedule.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
    [string]$LabelName = 'autoshutdown',
    [string]$LabelValue = 'yes',
    [string[]]$ProjectId,
    [switch]$Wait
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

if (-not $ProjectId) {
    $current = (& gcloud config get-value project 2>$null | Select-Object -Last 1)
    if (-not $current) { throw 'No -ProjectId given and no default project set. Use -ProjectId, or gcloud config set project.' }
    $ProjectId = @($current.Trim())
}

$summary = New-Object System.Collections.Generic.List[object]

foreach ($p in $ProjectId) {
    Write-Output "Project $p"
    try {
        $vms = @(Invoke-Gcloud @('compute', 'instances', 'list', "--project=$p", "--filter=labels.$($LabelName.ToLower()):*"))
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }
    $vms = $vms | Where-Object { $_ -and ([string]$_.labels.$($LabelName.ToLower())) -ieq $LabelValue }

    foreach ($vm in $vms) {
        $zone = Get-Leaf $vm.zone
        $row = [pscustomobject]@{ Project = $p; Zone = $zone; VM = $vm.name; Before = $vm.status; Result = '' }
        $createdBy = (@($vm.metadata.items) | Where-Object { $_.key -eq 'created-by' } | Select-Object -First 1).value

        if ($createdBy -match 'instanceGroupManagers') {
            $row.Result = 'Skipped (in a managed instance group)'
        } elseif (($Action -eq 'Stop' -and $vm.status -in 'TERMINATED', 'STOPPING', 'SUSPENDED') -or
                  ($Action -eq 'Start' -and $vm.status -in 'RUNNING', 'PROVISIONING', 'STAGING')) {
            $row.Result = 'Skipped (already in state)'
        } elseif ($PSCmdlet.ShouldProcess("$p/$zone/$($vm.name)", "$Action VM")) {
            $verb = $Action.ToLower()
            $cmd = @('compute', 'instances', $verb, $vm.name, "--zone=$zone", "--project=$p", '--quiet')
            if (-not $Wait) { $cmd += '--async' }
            $out = & gcloud @cmd 2>&1
            $row.Result = if ($LASTEXITCODE -eq 0) { if ($Wait) { 'Done' } else { 'Requested' } } else { "Failed: $(($out | Out-String).Trim())" }
        } else { continue }
        $summary.Add($row)
    }
}

# Write-Output (not Write-Host) so the summary appears in job and pipeline logs
$summary | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ("{0}: {1} VM(s) acted on, {2} skipped, {3} failed." -f $Action,
    @($summary | Where-Object { $_.Result -in 'Done', 'Requested' }).Count,
    @($summary | Where-Object { $_.Result -like 'Skipped*' }).Count,
    @($summary | Where-Object { $_.Result -like 'Failed*' }).Count)

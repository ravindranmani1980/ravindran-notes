<#
.SYNOPSIS
    Checks every Cloud Storage bucket for public access, and reports public access prevention, uniform access, versioning and soft delete.

.DESCRIPTION
    For each project, reads the effective storage.publicAccessPrevention organisation policy,
    then for every bucket reports:
    - Whether its IAM policy grants any role to allUsers or allAuthenticatedUsers
    - Public access prevention (enforced on the bucket, by organisation policy, or not at all)
    - Uniform bucket-level access, object versioning, soft delete retention and location
    Flags each bucket:
    - High: public grant in IAM and public access prevention not in force
    - Medium: public access prevention not in force (no public grant yet)
    - Low: a public grant that public access prevention is blocking (clean it up); uniform
      access off (object ACLs possible); no versioning and no soft delete

    Read-only: it doesn't change any settings.

.PARAMETER ProjectId
    Projects to check. Default: every active project you can see.

.PARAMETER ProblemsOnly
    Only list buckets with at least one finding.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-GcpBucketPublicAccessReport.ps1

.EXAMPLE
    .\Get-GcpBucketPublicAccessReport.ps1 -ProjectId prj-notes-test, prj-web-prod -ProblemsOnly -OutputFile .\buckets.csv

.NOTES
    Requires the Google Cloud CLI (gcloud), roles/storage.admin or roles/viewer plus
    storage.buckets.getIamPolicy on the buckets, and orgpolicy.policies.list on the projects
    (roles/orgpolicy.policyViewer). A bucket meant to be public (a static website) should
    normally sit behind a load balancer with Cloud CDN instead.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectId,
    [switch]$ProblemsOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('GcpBucketPublicAccessReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
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
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }

foreach ($p in Get-TargetProject $ProjectId) {
    Write-Host "Project $p..." -ForegroundColor Cyan
    try {
        $buckets = @(Invoke-Gcloud @('storage', 'buckets', 'list', "--project=$p"))
    } catch {
        Write-Warning "Skipping $p`: $($_.Exception.Message)"
        continue
    }
    if (-not $buckets) { continue }

    # Is public access prevention enforced for the whole project by organisation policy?
    $orgEnforced = $false
    try {
        $policy = Invoke-Gcloud @('org-policies', 'describe', 'storage.publicAccessPrevention', "--project=$p", '--effective')
        $orgEnforced = [bool](@($policy.spec.rules) | Where-Object { $_.enforce -eq $true -or $_.enforce -eq 'true' })
    } catch {
        Write-Warning "Can't read the organisation policy for $p; treating public access prevention as not enforced by policy."
    }

    foreach ($b in $buckets) {
        $findings = New-Object System.Collections.Generic.List[object]
        $name = $b.name

        $publicMembers = @()
        try {
            $iam = Invoke-Gcloud @('storage', 'buckets', 'get-iam-policy', "gs://$name")
            $publicMembers = @(@($iam.bindings) | Where-Object { $_ } | ForEach-Object {
                $role = $_.role; @($_.members) | Where-Object { $_ -in 'allUsers', 'allAuthenticatedUsers' } | ForEach-Object { "$_ ($role)" } })
        } catch {
            $findings.Add(@('Medium', "Could not read IAM policy: $($_.Exception.Message)"))
        }

        $pap = [string]$b.public_access_prevention
        $papInForce = $pap -eq 'enforced' -or $orgEnforced
        $papText = if ($pap -eq 'enforced') { 'Enforced on bucket' } elseif ($orgEnforced) { 'Enforced by org policy' } else { 'Not enforced' }

        $soft = $b.soft_delete_policy
        $softSeconds = if ($soft) { [double]$(if ($soft.retentionDurationSeconds) { $soft.retentionDurationSeconds } else { $soft.retention_duration_seconds }) } else { 0 }
        $softDays = [math]::Round($softSeconds / 86400, 1)
        $versioning = [bool]$b.versioning_enabled
        $ubla = [bool]$b.uniform_bucket_level_access

        if ($publicMembers -and -not $papInForce) { $findings.Add(@('High', ('Public: ' + ($publicMembers -join ', ')))) }
        elseif ($publicMembers) { $findings.Add(@('Low', ('Public grant blocked by public access prevention: ' + ($publicMembers -join ', ')))) }
        if (-not $papInForce -and -not $publicMembers) { $findings.Add(@('Medium', 'Public access prevention not enforced')) }
        if (-not $ubla) { $findings.Add(@('Low', 'Uniform bucket-level access off (object ACLs possible)')) }
        if (-not $versioning -and $softDays -le 0) { $findings.Add(@('Low', 'No versioning and no soft delete')) }

        if ($ProblemsOnly -and -not $findings.Count) { continue }
        $top = $findings | Sort-Object { $rank[$_[0]] } | Select-Object -First 1
        $report.Add([pscustomobject]@{
            Severity               = if ($top) { $top[0] } else { '' }
            Project                = $p
            Bucket                 = $name
            Location               = $b.location
            Findings               = ($findings | ForEach-Object { $_[1] }) -join '; '
            PublicAccessPrevention = $papText
            UniformAccess          = $ubla
            Versioning             = $versioning
            SoftDeleteDays         = $softDays
            Owner                  = if ($b.labels) { $b.labels.owner } else { '' }
        })
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Project, Bucket
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Buckets reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

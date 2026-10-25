<#
.SYNOPSIS
    Exports AWS Config conformance pack results, such as the FDA 21 CFR Part 11 pack, as review evidence.

.DESCRIPTION
    For each account and region, finds the conformance packs whose name matches -PackName
    (by default any pack with "Part-11", "Part11" or "21CFR" in its name), and exports every rule
    evaluation: rule, resource, compliance, annotation and when it was evaluated. A summary
    per pack and rule is shown on screen.

    Deploy the sample pack "Operational Best Practices for FDA Title 21 CFR Part 11" from
    the AWS Config console (or from the awslabs/aws-config-rules repository) before using this.
    A compliant pack result is supporting evidence for infrastructure controls, not proof that
    a system meets Part 11: most Part 11 requirements sit in the application and procedures.

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER Region
    Regions to check. Default: every region enabled in the account.

.PARAMETER PackName
    Conformance pack names to report. Wildcards allowed. Default: *Part-11*, *Part11*, *21CFR*.

.PARAMETER NonCompliantOnly
    Only list evaluations that are NON_COMPLIANT.

.PARAMETER HomeRegion
    Region used for account-level calls (STS, listing regions). Default us-east-1.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsGxPConformanceReport.ps1 -ProfileName notes-gxp -Region us-east-1

.EXAMPLE
    .\Get-AwsGxPConformanceReport.ps1 -ProfileName notes-gxp -PackName 'gxp-*' -NonCompliantOnly

.NOTES
    Requires AWS.Tools.ConfigService, AWS.Tools.EC2 and AWS.Tools.SecurityToken, and read
    access to AWS Config. The AWS Config recorder must be on in each region the pack covers,
    or rules have nothing to evaluate.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$Region,
    [string[]]$PackName = @('*Part-11*', '*Part11*', '*21CFR*'),
    [switch]$NonCompliantOnly,
    [string]$HomeRegion = 'us-east-1',
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsGxPConformance_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

$modules = @('AWS.Tools.ConfigService', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken')
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule $($modules -join ', ')" }
    Import-Module $m -ErrorAction Stop
}

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters, [string]$RunAs)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# AWS caller: $RunAs"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

$report = New-Object System.Collections.Generic.List[object]
$callers = @()
$packsFound = 0
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $identity = Get-STSCallerIdentity @cred -Region $HomeRegion
    $account = $identity.Account
    $callers += $identity.Arn
    $regions = if ($Region) { $Region } else { @((Get-EC2Region @cred -Region $HomeRegion).RegionName) }

    foreach ($r in $regions) {
        $c = @{ Region = $r } + $cred
        try { $packs = @(Get-CFGConformancePack @c -ErrorAction Stop) | Where-Object { $_ } }
        catch { Write-Warning "Skipping $r in $account`: $($_.Exception.Message)"; continue }
        $packs = @($packs | Where-Object { $n = $_.ConformancePackName; @($PackName | Where-Object { $n -like $_ }).Count })
        if (-not $packs) { continue }
        Write-Host "Account $account, region $r`: $($packs.Count) pack(s)" -ForegroundColor Cyan

        foreach ($pack in $packs) {
            $packsFound++
            $filter = @{}
            if ($NonCompliantOnly) { $filter.Filter_ComplianceType = 'NON_COMPLIANT' }
            try {
                $results = @(Get-CFGConformancePackComplianceDetail @c -ConformancePackName $pack.ConformancePackName @filter -ErrorAction Stop) | Where-Object { $_ }
            } catch { Write-Warning "$($pack.ConformancePackName) in $r`: $($_.Exception.Message)"; continue }

            foreach ($e in $results) {
                $q = $e.EvaluationResultIdentifier.EvaluationResultQualifier
                $report.Add([pscustomobject]@{
                    Account        = $account
                    Region         = $r
                    Pack           = $pack.ConformancePackName
                    Rule           = $q.ConfigRuleName
                    Compliance     = [string]$e.ComplianceType
                    ResourceType   = $q.ResourceType
                    ResourceId     = $q.ResourceId
                    Annotation     = $e.Annotation
                    EvaluatedAt    = $e.ConfigRuleInvokedTime
                    RecordedAt     = $e.ResultRecordedTime
                })
            }
        }
    }
}

if (-not $packsFound) { Write-Warning "No conformance pack matching '$($PackName -join "', '")' was found. Deploy the FDA 21 CFR Part 11 sample pack first."; return }

$order = @{ 'NON_COMPLIANT' = 0; 'INSUFFICIENT_DATA' = 1; 'NOT_APPLICABLE' = 2; 'COMPLIANT' = 3 }
$report | Sort-Object @{e = { $order[$_.Compliance] }}, Account, Region, Pack, Rule, ResourceId | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters -RunAs ($callers -join ', ')

$report | Group-Object Pack, Rule | ForEach-Object {
    [pscustomobject]@{
        Rule         = ($_.Name -split ', ', 2)[1]
        NonCompliant = @($_.Group | Where-Object Compliance -eq 'NON_COMPLIANT').Count
        Compliant    = @($_.Group | Where-Object Compliance -eq 'COMPLIANT').Count
    }
} | Sort-Object NonCompliant -Descending | Format-Table -AutoSize | Out-Host
Write-Host "Evaluations: $($report.Count), non-compliant: $(@($report | Where-Object Compliance -eq 'NON_COMPLIANT').Count). Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

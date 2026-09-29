<#
.SYNOPSIS
    Checks every S3 bucket for public access, and reports Block Public Access, policy status, ACLs, encryption and versioning.

.DESCRIPTION
    For each account, reads the account-level S3 Block Public Access setting, then for every
    bucket reports:
    - Block Public Access settings on the bucket (all four on, or which are off)
    - Whether the bucket policy makes it public, and whether its ACL grants access to everyone
    - Object Ownership (ACLs disabled or not), default encryption and versioning
    Flags each bucket:
    - High: the policy is public, or the ACL grants AllUsers or AuthenticatedUsers
    - Medium: Block Public Access isn't fully on for the bucket or the account
    - Low: versioning off, or ACLs still enabled

    Read-only: it doesn't change any settings.

.PARAMETER ProfileName
    AWS profiles to check, one per account. Default: the current credentials.

.PARAMETER BucketName
    Check only these buckets. Default: every bucket in the account.

.PARAMETER ProblemsOnly
    Only list buckets with at least one finding.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AwsS3PublicAccessReport.ps1

.EXAMPLE
    .\Get-AwsS3PublicAccessReport.ps1 -ProfileName notes-test, notes-prod -ProblemsOnly -OutputFile .\s3.csv

.NOTES
    Requires AWS.Tools.S3, AWS.Tools.S3Control and AWS.Tools.SecurityToken, and read access
    (s3:GetBucket* and s3:GetAccountPublicAccessBlock, included in SecurityAudit). A bucket
    whose settings can't be read (for example, denied by its own bucket policy) is reported
    with the error rather than skipped. Buckets meant to be public (a static website) should
    normally be private behind CloudFront instead.
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,
    [string[]]$BucketName,
    [switch]$ProblemsOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AwsS3PublicAccessReport_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

foreach ($m in 'AWS.Tools.S3', 'AWS.Tools.S3Control', 'AWS.Tools.SecurityToken') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Run: Install-AWSToolsModule AWS.Tools.S3, AWS.Tools.S3Control, AWS.Tools.SecurityToken" }
    Import-Module $m -ErrorAction Stop
}

# Returns 'All on' or the names of the settings that are off
function Get-BpaSummary {
    param($Config)
    if (-not $Config) { return 'Not set' }
    $off = @()
    if (-not $Config.BlockPublicAcls) { $off += 'BlockPublicAcls' }
    if (-not $Config.IgnorePublicAcls) { $off += 'IgnorePublicAcls' }
    if (-not $Config.BlockPublicPolicy) { $off += 'BlockPublicPolicy' }
    if (-not $Config.RestrictPublicBuckets) { $off += 'RestrictPublicBuckets' }
    if ($off) { 'Off: ' + ($off -join ', ') } else { 'All on' }
}

# Runs a read call; returns $null when the setting doesn't exist (the S3 APIs throw for that)
function Invoke-Quietly {
    param([scriptblock]$Call)
    try { & $Call } catch { $null }
}

$report = New-Object System.Collections.Generic.List[object]
$rank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; '' = 3 }
$everyone = 'http://acs.amazonaws.com/groups/global/AllUsers', 'http://acs.amazonaws.com/groups/global/AuthenticatedUsers'
$targets = if ($ProfileName) { $ProfileName } else { @('') }

foreach ($p in $targets) {
    $cred = @{}
    if ($p) { $cred.ProfileName = $p }
    $account = (Get-STSCallerIdentity @cred -Region us-east-1).Account
    $accountBpa = Invoke-Quietly { Get-S3CPublicAccessBlock @cred -Region us-east-1 -AccountId $account -ErrorAction Stop }
    $accountSummary = Get-BpaSummary $accountBpa
    Write-Host "Account ${account}: account-level Block Public Access $accountSummary" -ForegroundColor Cyan

    $buckets = @(Get-S3Bucket @cred -Region us-east-1) | Where-Object { $_ -and (-not $BucketName -or $BucketName -contains $_.BucketName) }
    foreach ($b in $buckets) {
        $name = $b.BucketName
        $findings = New-Object System.Collections.Generic.List[object]
        $errorText = ''
        try {
            $loc = [string](Get-S3BucketLocation @cred -Region us-east-1 -BucketName $name -ErrorAction Stop).Value
            $r = switch ($loc) { '' { 'us-east-1' } 'EU' { 'eu-west-1' } default { $loc } }
        } catch {
            $r = ''; $errorText = $_.Exception.Message
        }

        $bucketBpa = $null; $policyPublic = $null; $aclPublic = $false; $ownership = ''; $encryption = ''; $versioning = ''
        if ($r) {
            $c = @{ Region = $r; BucketName = $name } + $cred
            $bucketBpa = Invoke-Quietly { Get-S3PublicAccessBlock @c -ErrorAction Stop }
            $status = Invoke-Quietly { Get-S3BucketPolicyStatus @c -ErrorAction Stop }
            $policyPublic = if ($status) { [bool]$status.IsPublic } else { $false }
            $acl = Invoke-Quietly { Get-S3ACL @c -ErrorAction Stop }
            $aclPublic = [bool](@($acl.Grants) | Where-Object { $_ -and $everyone -contains $_.Grantee.URI })
            $own = Invoke-Quietly { Get-S3BucketOwnershipControl @c -ErrorAction Stop }
            $ownership = [string](@($own.Rules) | Select-Object -First 1).ObjectOwnership
            if (-not $ownership) { $ownership = 'ObjectWriter (ACLs enabled)' }
            $enc = Invoke-Quietly { Get-S3BucketEncryption @c -ErrorAction Stop }
            $encryption = [string](@($enc.ServerSideEncryptionRules) | Select-Object -First 1).ServerSideEncryptionByDefault.ServerSideEncryptionAlgorithm
            $versioning = [string](Invoke-Quietly { Get-S3BucketVersioning @c -ErrorAction Stop }).Status
            if (-not $versioning) { $versioning = 'Off' }
        }
        $bucketSummary = Get-BpaSummary $bucketBpa

        if ($policyPublic) { $findings.Add(@('High', 'Bucket policy is public')) }
        if ($aclPublic) { $findings.Add(@('High', 'ACL grants access to everyone')) }
        if ($bucketSummary -ne 'All on' -and $accountSummary -ne 'All on') { $findings.Add(@('Medium', 'Block Public Access not fully on (bucket or account)')) }
        if ($r -and $versioning -ne 'Enabled') { $findings.Add(@('Low', "Versioning $versioning")) }
        if ($r -and $ownership -ne 'BucketOwnerEnforced') { $findings.Add(@('Low', 'ACLs enabled')) }
        if ($errorText) { $findings.Add(@('Medium', "Could not read settings: $errorText")) }

        if ($ProblemsOnly -and -not $findings.Count) { continue }
        $top = $findings | Sort-Object { $rank[$_[0]] } | Select-Object -First 1
        $report.Add([pscustomobject]@{
            Account          = $account
            Severity         = if ($top) { $top[0] } else { '' }
            Bucket           = $name
            Region           = $r
            Findings         = ($findings | ForEach-Object { $_[1] }) -join '; '
            AccountBPA       = $accountSummary
            BucketBPA        = $bucketSummary
            PolicyPublic     = $policyPublic
            AclPublic        = $aclPublic
            ObjectOwnership  = $ownership
            Encryption       = $encryption
            Versioning       = $versioning
            Created          = $b.CreationDate
        })
    }
}

$report = $report | Sort-Object @{e = { $rank[$_.Severity] }}, Account, Bucket
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
$report | Where-Object Severity | Group-Object Severity | Select-Object @{n='Severity';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Buckets reported: $(@($report).Count). Report: $OutputFile" -ForegroundColor Green

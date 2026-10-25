<#
.SYNOPSIS
    Checks that Azure activity logs and resource logs for GxP scope are exported and kept long enough.

.DESCRIPTION
    Platform logs are part of the audit trail for the infrastructure under a GxP system. Azure
    keeps the activity log for 90 days and resource logs not at all unless you export them, so
    this script checks, for each GxP-tagged subscription or resource group:
    - Subscription activity log: is there a diagnostic setting sending it to a Log Analytics
      workspace or storage account?
    - Resources that hold GxP data or control access to it (Key Vault, SQL databases, storage
      accounts, App Service, PostgreSQL and MySQL flexible servers, Recovery Services vaults,
      AKS, Logic Apps, Application Gateways): does each one have a diagnostic setting with
      logs enabled?
    - Log Analytics destinations: is the workspace retention at least -MinRetentionDays?

    Each row gets a Status: Covered, Retention too short, Logs not exported or Check manually.

    A .sha256 file is written next to the CSV with the file hash, who ran it, when and with
    which parameters.

    Read-only: it doesn't change anything.

.PARAMETER SubscriptionId
    Subscriptions to check. Default: every enabled subscription you can read.

.PARAMETER TagName
    Tag that marks GxP scope. Default GxP.

.PARAMETER TagValue
    Tag value that marks GxP scope. Default Yes.

.PARAMETER AllScopes
    Ignore the tag and treat every subscription checked as GxP scope.

.PARAMETER MinRetentionDays
    Minimum Log Analytics retention your procedures require. Default 365. Storage account
    destinations are reported, but their retention (lifecycle rules, immutability) must be
    checked separately.

.PARAMETER GapsOnly
    Only list rows that are not Covered.

.PARAMETER OutputFile
    CSV output path.

.EXAMPLE
    .\Get-AzGxPAuditLogCoverage.ps1

.EXAMPLE
    .\Get-AzGxPAuditLogCoverage.ps1 -MinRetentionDays 730 -GapsOnly

.NOTES
    Requires Az.Accounts, Az.Resources and Az.Monitor, and Reader on the subscriptions and
    on the Log Analytics workspaces used as destinations. Log Analytics "retention" here is the
    interactive retention of the workspace; tables can have their own retention and long-term
    (archive) retention, so check those in the portal if a table differs from the workspace.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$TagName = 'GxP',
    [string]$TagValue = 'Yes',
    [switch]$AllScopes,
    [ValidateRange(30, 4383)][int]$MinRetentionDays = 365,
    [switch]$GapsOnly,
    [string]$OutputFile = (Join-Path -Path (Get-Location) -ChildPath ('AzGxPAuditLogCoverage_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)))
)

if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }

function Write-EvidenceManifest {
    param([string]$Path, [hashtable]$Parameters)
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $params = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value -join ',')" }) -join ' '
    @(
        "$hash  $(Split-Path -Path $Path -Leaf)"
        "# Script:     $(Split-Path -Path $PSCommandPath -Leaf)"
        "# Run by:     $([Environment]::UserName) on $([Environment]::MachineName)"
        "# Signed in:  $((Get-AzContext).Account.Id)"
        "# Run at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        "# Parameters: $params"
    ) | Set-Content -Path "$Path.sha256" -Encoding UTF8
}

function Get-TagValue($Tags, [string]$Name) {
    if (-not $Tags) { return $null }
    foreach ($k in $Tags.Keys) { if ($k -eq $Name) { return $Tags[$k] } }
    return $null
}

# Resource types checked, and the sub-resource that carries the diagnostic setting where it differs
$types = [ordered]@{
    'Microsoft.KeyVault/vaults'                    = ''
    'Microsoft.Sql/servers/databases'              = ''
    'Microsoft.Storage/storageAccounts'            = '/blobServices/default'
    'Microsoft.Web/sites'                          = ''
    'Microsoft.DBforPostgreSQL/flexibleServers'    = ''
    'Microsoft.DBforMySQL/flexibleServers'         = ''
    'Microsoft.RecoveryServices/vaults'            = ''
    'Microsoft.ContainerService/managedClusters'   = ''
    'Microsoft.Logic/workflows'                    = ''
    'Microsoft.Network/applicationGateways'        = ''
}

$workspaceRetention = @{}
function Get-WorkspaceRetention([string]$WorkspaceId) {
    if (-not $workspaceRetention.ContainsKey($WorkspaceId)) {
        try { $workspaceRetention[$WorkspaceId] = [int](Get-AzResource -ResourceId $WorkspaceId -ExpandProperties -ErrorAction Stop).Properties.retentionInDays }
        catch { $workspaceRetention[$WorkspaceId] = $null }
    }
    return $workspaceRetention[$WorkspaceId]
}

# Turns a list of diagnostic settings into Destinations, Retention and Status
function Get-Coverage($Settings) {
    $withLogs = @($Settings | Where-Object {
        ($_.Log | Where-Object { $_.Enabled }) -and ($_.WorkspaceId -or $_.StorageAccountId -or $_.EventHubAuthorizationRuleId)
    })
    if (-not $withLogs) { return @{ Setting = (@($Settings).Name -join ', '); Destinations = ''; Retention = $null; Status = 'Logs not exported' } }

    $dest = New-Object System.Collections.Generic.List[string]
    $retentions = @()
    foreach ($s in $withLogs) {
        if ($s.WorkspaceId) { $dest.Add('Log Analytics: ' + ($s.WorkspaceId -split '/')[-1]); $retentions += Get-WorkspaceRetention $s.WorkspaceId }
        if ($s.StorageAccountId) { $dest.Add('Storage: ' + ($s.StorageAccountId -split '/')[-1]) }
        if ($s.EventHubAuthorizationRuleId) { $dest.Add('Event Hub: ' + ($s.EventHubAuthorizationRuleId -split '/')[-3]) }
    }
    $best = ($retentions | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
    $status = if ($best -ge $MinRetentionDays) { 'Covered' }
              elseif ($null -ne $best -and -not ($withLogs | Where-Object StorageAccountId)) { 'Retention too short' }
              else { 'Check manually' }   # storage or event hub only: retention is set elsewhere
    return @{ Setting = ($withLogs.Name -join ', '); Destinations = ($dest | Select-Object -Unique) -join '; '; Retention = $best; Status = $status }
}

$subs = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' })
if ($SubscriptionId) { $subs = @($subs | Where-Object { $SubscriptionId -contains $_.Id }) }

$report = New-Object System.Collections.Generic.List[object]
foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    $subTags = (Get-AzTag -ResourceId "/subscriptions/$($sub.Id)" -ErrorAction SilentlyContinue).Properties.TagsProperty
    $wholeSub = $AllScopes -or (Get-TagValue $subTags $TagName) -eq $TagValue
    $gxpGroups = if ($wholeSub) { @() } else { @(Get-AzResourceGroup | Where-Object { (Get-TagValue $_.Tags $TagName) -eq $TagValue } | ForEach-Object { $_.ResourceGroupName }) }
    if (-not $wholeSub -and -not $gxpGroups) { Write-Verbose "No GxP scope in $($sub.Name)"; continue }
    Write-Host "Checking $($sub.Name)..." -ForegroundColor Cyan

    # The activity log is per subscription, so it's in scope whenever anything in the subscription is
    $c = Get-Coverage @(Get-AzSubscriptionDiagnosticSetting -SubscriptionId $sub.Id -ErrorAction SilentlyContinue)
    $report.Add([pscustomobject]@{
        Subscription = $sub.Name; ResourceGroup = ''; ResourceType = 'Activity log (subscription)'; Resource = $sub.Name
        DiagnosticSetting = $c.Setting; Destinations = $c.Destinations; RetentionDays = $c.Retention; Status = $c.Status
        Note = if ($c.Status -eq 'Logs not exported') { 'Azure keeps the activity log for 90 days only' } else { '' }
    })

    $resources = @(Get-AzResource | Where-Object { $types.Contains($_.ResourceType) -and ($wholeSub -or $gxpGroups -contains $_.ResourceGroupName) })
    foreach ($res in $resources) {
        $target = $res.ResourceId + $types[$res.ResourceType]
        try {
            $c = Get-Coverage @(Get-AzDiagnosticSetting -ResourceId $target -ErrorAction Stop)
            $note = ''
        } catch {
            $c = @{ Setting = ''; Destinations = ''; Retention = $null; Status = 'Check manually' }
            $note = "Could not read diagnostic settings: $($_.Exception.Message)"
        }
        if ($res.ResourceType -eq 'Microsoft.Storage/storageAccounts') { $note = ('Blob service checked. ' + $note).Trim() }
        $report.Add([pscustomobject]@{
            Subscription = $sub.Name; ResourceGroup = $res.ResourceGroupName; ResourceType = $res.ResourceType; Resource = $res.Name
            DiagnosticSetting = $c.Setting; Destinations = $c.Destinations; RetentionDays = $c.Retention; Status = $c.Status; Note = $note
        })
    }
}

if (-not $report.Count) { Write-Warning "No GxP scope found. Tag subscriptions or resource groups $TagName = $TagValue, or use -AllScopes."; return }

$out = if ($GapsOnly) { @($report | Where-Object Status -ne 'Covered') } else { $report }
$order = @{ 'Logs not exported' = 0; 'Retention too short' = 1; 'Check manually' = 2; 'Covered' = 3 }
$out | Sort-Object @{e = { $order[$_.Status] }}, Subscription, ResourceType, Resource | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-EvidenceManifest -Path $OutputFile -Parameters $PSBoundParameters

$report | Group-Object Status | Select-Object @{n='Status';e={$_.Name}}, Count | Format-Table -AutoSize | Out-Host
Write-Host "Report: $OutputFile (hash in $OutputFile.sha256)" -ForegroundColor Green

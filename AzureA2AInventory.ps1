<#
.SYNOPSIS
Read-only Azure inventory + dependency export to prepare for an Azure-to-Azure
(tenant/subscription consolidation) move.

.DESCRIPTION
Runs read-only Azure control-plane queries (and optional Log Analytics queries)
to capture:
  - Management group hierarchy
  - Subscriptions
  - All resources + summaries by type/location
  - Virtual machines and disks
  - Networking (VNets, subnets, NSGs, route tables, firewalls, gateways, ER circuits)
  - VNet peerings (structural connectivity: which VNet connects to which)
  - Private endpoints and private DNS zones
  - Key Vaults and managed identities
  - Log Analytics / App Insights components (discovery)
  - OPTIONAL: VM Insights network connections (who-talks-to-who) from Log Analytics
  - OPTIONAL: Application Insights app dependencies (app -> backend calls)

The script does NOT install agents, does NOT modify resources, and only reads
metadata and (optionally) existing monitoring data that is already being collected.

.PREREQUISITES
PowerShell 7+ recommended.
  Install-Module Az.Accounts, Az.ResourceGraph, Az.Resources, Az.OperationalInsights, Az.ApplicationInsights -Scope CurrentUser

.PARAMETER TenantId
Tenant to sign into. If omitted, uses the default tenant for the account.

.PARAMETER IncludeRoleAssignments
Also export RBAC role assignments per subscription (needs Microsoft.Authorization/roleAssignments/read).

.PARAMETER IncludePolicyAssignments
Also export policy assignments per subscription.

.PARAMETER IncludeVmInsightsConnections
Query each discovered Log Analytics workspace for VM Insights connection data
(VMConnection table) to map server-to-server / VM-to-VM traffic. Needs Log Analytics Reader.

.PARAMETER IncludeAppInsightsDependencies
Query each discovered Application Insights component for outbound dependencies
(app -> SQL / HTTP / storage / etc). Needs Monitoring Reader on the App Insights resource.

.PARAMETER LookbackDays
How many days of monitoring data to pull for VM Insights / App Insights queries. Default 30.

.PARAMETER UseDeviceAuthentication
Sign in with device-code flow (prints a URL + code) instead of the interactive
browser popup. Use this when the browser popup crashes the terminal or in
headless/remote sessions. Enter the code promptly at https://login.microsoft.com/device.

.PARAMETER IncludeDependencies
Convenience switch that enables BOTH -IncludeVmInsightsConnections and
-IncludeAppInsightsDependencies at once.

.EXAMPLE
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>"

.EXAMPLE
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>" -UseDeviceAuthentication -IncludeRoleAssignments

.EXAMPLE
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>" -UseDeviceAuthentication -IncludeDependencies -LookbackDays 30
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$OutputPath = ".\azure-a2a-inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$IncludeRoleAssignments,
    [switch]$IncludePolicyAssignments,
    [switch]$IncludeVmInsightsConnections,
    [switch]$IncludeAppInsightsDependencies,
    [switch]$IncludeDependencies,
    [switch]$UseDeviceAuthentication,
    [int]$LookbackDays = 30
)

$ErrorActionPreference = "Stop"

# -IncludeDependencies is a convenience switch that turns on BOTH dependency exports.
if ($IncludeDependencies) {
    $IncludeVmInsightsConnections   = $true
    $IncludeAppInsightsDependencies = $true
}

function Test-RequiredModule {
    param([string]$Name, [switch]$Optional)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if ($Optional) {
            Write-Warning "Optional module '$Name' not found. Related export will be skipped. Install with: Install-Module $Name -Scope CurrentUser"
            return $false
        }
        throw "Missing required module '$Name'. Install with: Install-Module $Name -Scope CurrentUser"
    }
    return $true
}

function Export-Object {
    param([object[]]$Data, [string]$Name)
    if (-not $Data) { $Data = @() }
    $csvPath  = Join-Path $OutputPath "$Name.csv"
    $jsonPath = Join-Path $OutputPath "$Name.json"
    $Data | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $Data | ConvertTo-Json -Depth 25 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Host ("  {0,-40} {1,6} rows" -f $Name, @($Data).Count)
}

function Invoke-ResourceGraphQueryAll {
    param([string]$Query, [string[]]$SubscriptionIds)
    $allRows = New-Object System.Collections.Generic.List[object]
    $skipToken = $null
    do {
        $params = @{ Query = $Query; Subscription = $SubscriptionIds; First = 1000 }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $result = Search-AzGraph @params
        foreach ($row in $result.Data) { $allRows.Add($row) }
        $skipToken = $result.SkipToken
    } while ($skipToken)
    return $allRows.ToArray()
}

# ---- Module checks ----
Test-RequiredModule -Name "Az.Accounts"      | Out-Null
Test-RequiredModule -Name "Az.ResourceGraph" | Out-Null
Test-RequiredModule -Name "Az.Resources"     | Out-Null
$haveLA  = if ($IncludeVmInsightsConnections)   { Test-RequiredModule -Name "Az.OperationalInsights" -Optional } else { $false }
$haveAI  = if ($IncludeAppInsightsDependencies) { Test-RequiredModule -Name "Az.ApplicationInsights" -Optional } else { $false }

Import-Module Az.Accounts
Import-Module Az.ResourceGraph
Import-Module Az.Resources
if ($haveLA) { Import-Module Az.OperationalInsights }
if ($haveAI) { Import-Module Az.ApplicationInsights }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ---- Connect ----
$connectParams = @{}
if ($TenantId)                { $connectParams.Tenant = $TenantId }
if ($UseDeviceAuthentication) { $connectParams.UseDeviceAuthentication = $true }
Connect-AzAccount @connectParams | Out-Null
$context = Get-AzContext
$tenant  = $context.Tenant.Id

$subscriptions = Get-AzSubscription -TenantId $tenant | Where-Object { $_.State -eq "Enabled" }
if (-not $subscriptions) { throw "No enabled subscriptions found for tenant '$tenant'." }
$subscriptionIds = $subscriptions.Id

Write-Host ""
Write-Host "Tenant: $tenant"
Write-Host "Enabled subscriptions: $($subscriptions.Count)"
Write-Host "Exporting to: $OutputPath"
Write-Host ""

# ---- Management groups ----
Write-Host "Exporting governance scope..."
try {
    $mgFlat = Get-AzManagementGroup -ErrorAction Stop | Select-Object Name, DisplayName, Id, TenantId
    Export-Object -Name "management-groups" -Data $mgFlat

    $mgHierarchy = foreach ($mg in $mgFlat) {
        try {
            $detail = Get-AzManagementGroup -GroupName $mg.Name -Expand -Recurse -ErrorAction Stop
            $detail.Children | ForEach-Object {
                [pscustomobject]@{
                    parentName        = $mg.Name
                    parentDisplayName = $mg.DisplayName
                    childType         = $_.Type
                    childName         = $_.Name
                    childDisplayName  = $_.DisplayName
                    childId           = $_.Id
                }
            }
        } catch { }
    }
    Export-Object -Name "management-group-hierarchy" -Data $mgHierarchy
} catch {
    Write-Warning "Management groups not accessible (needs Management Group Reader). Skipping. $($_.Exception.Message)"
}

Export-Object -Name "subscriptions" -Data ($subscriptions | Select-Object Id, Name, State, TenantId)

# ---- Resource Graph queries ----
$queries = [ordered]@{

  "resources" = @"
Resources
| project subscriptionId, resourceGroup, name, type, location, kind,
          sku = tostring(sku.name), tags = tostring(tags), id
| order by subscriptionId, resourceGroup, type, name
"@

  "resource-summary-by-type" = @"
Resources
| summarize resourceCount = count() by subscriptionId, type
| order by resourceCount desc
"@

  "resource-groups" = @"
ResourceContainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| project subscriptionId, name, location, tags = tostring(tags), id
| order by subscriptionId, name
"@

  "virtual-machines" = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project subscriptionId, resourceGroup, name, location,
          vmSize = tostring(properties.hardwareProfile.vmSize),
          osType = tostring(properties.storageProfile.osDisk.osType),
          powerState = tostring(properties.extended.instanceView.powerState.displayStatus),
          licenseType = tostring(properties.licenseType),
          zones = tostring(zones), id
| order by subscriptionId, resourceGroup, name
"@

  "disks" = @"
Resources
| where type =~ 'microsoft.compute/disks'
| project subscriptionId, resourceGroup, name, location,
          sku = tostring(sku.name), diskSizeGB = tostring(properties.diskSizeGB),
          diskState = tostring(properties.diskState), id
| order by subscriptionId, resourceGroup, name
"@

  "networking" = @"
Resources
| where type in~ (
    'microsoft.network/virtualnetworks','microsoft.network/networkinterfaces',
    'microsoft.network/networksecuritygroups','microsoft.network/routetables',
    'microsoft.network/azurefirewalls','microsoft.network/applicationgateways',
    'microsoft.network/loadbalancers','microsoft.network/publicipaddresses',
    'microsoft.network/privateendpoints','microsoft.network/privatednszones',
    'microsoft.network/virtualnetworkgateways','microsoft.network/expressroutecircuits',
    'microsoft.network/connections')
| project subscriptionId, resourceGroup, name, type, location, tags = tostring(tags), id
| order by subscriptionId, resourceGroup, type, name
"@

  "vnets-subnets" = @"
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets to typeof(dynamic)
| project subscriptionId, resourceGroup, vnetName = name, location,
          addressPrefixes = tostring(properties.addressSpace.addressPrefixes),
          subnetName = tostring(subnet.name),
          subnetPrefix = tostring(subnet.properties.addressPrefix),
          routeTableId = tostring(subnet.properties.routeTable.id),
          nsgId = tostring(subnet.properties.networkSecurityGroup.id), id
| order by subscriptionId, resourceGroup, vnetName, subnetName
"@

  "vnet-peerings" = @"
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand peering = properties.virtualNetworkPeerings to typeof(dynamic)
| project subscriptionId, resourceGroup, localVnet = name, location,
          peeringName = tostring(peering.name),
          peeringState = tostring(peering.properties.peeringState),
          remoteVnetId = tostring(peering.properties.remoteVirtualNetwork.id),
          allowForwardedTraffic = tostring(peering.properties.allowForwardedTraffic),
          allowGatewayTransit = tostring(peering.properties.allowGatewayTransit),
          useRemoteGateways = tostring(peering.properties.useRemoteGateways),
          id
| order by subscriptionId, resourceGroup, localVnet, peeringName
"@

  "nsg-rules" = @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| mv-expand rule = properties.securityRules to typeof(dynamic)
| project subscriptionId, resourceGroup, nsgName = name, location,
          ruleName = tostring(rule.name),
          direction = tostring(rule.properties.direction),
          access = tostring(rule.properties.access),
          protocol = tostring(rule.properties.protocol),
          priority = tostring(rule.properties.priority),
          sourceAddressPrefix = tostring(rule.properties.sourceAddressPrefix),
          sourcePortRange = tostring(rule.properties.sourcePortRange),
          destinationAddressPrefix = tostring(rule.properties.destinationAddressPrefix),
          destinationPortRange = tostring(rule.properties.destinationPortRange),
          id
| order by subscriptionId, resourceGroup, nsgName, priority
"@

  "private-endpoints" = @"
Resources
| where type =~ 'microsoft.network/privateendpoints'
| project subscriptionId, resourceGroup, name, location,
          subnetId = tostring(properties.subnet.id),
          privateLinkServiceConnections = tostring(properties.privateLinkServiceConnections),
          id
| order by subscriptionId, resourceGroup, name
"@

  "key-vaults" = @"
Resources
| where type =~ 'microsoft.keyvault/vaults'
| project subscriptionId, resourceGroup, name, location,
          enableRbacAuthorization = tostring(properties.enableRbacAuthorization),
          publicNetworkAccess = tostring(properties.publicNetworkAccess), id
| order by subscriptionId, resourceGroup, name
"@

  "managed-identities" = @"
Resources
| where isnotempty(identity.type)
| project subscriptionId, resourceGroup, name, type, location,
          identityType = tostring(identity.type),
          principalId = tostring(identity.principalId), id
| order by subscriptionId, resourceGroup, type, name
"@

  "log-analytics-workspaces" = @"
Resources
| where type =~ 'microsoft.operationalinsights/workspaces'
| project subscriptionId, resourceGroup, name, location,
          customerId = tostring(properties.customerId),
          sku = tostring(properties.sku.name), id
| order by subscriptionId, resourceGroup, name
"@

  "app-insights-components" = @"
Resources
| where type =~ 'microsoft.insights/components'
| project subscriptionId, resourceGroup, name, location,
          appId = tostring(properties.AppId),
          applicationType = tostring(properties.Application_Type),
          workspaceResourceId = tostring(properties.WorkspaceResourceId), id
| order by subscriptionId, resourceGroup, name
"@
}

Write-Host "Exporting inventory (Resource Graph)..."
foreach ($queryName in $queries.Keys) {
    $rows = Invoke-ResourceGraphQueryAll -Query $queries[$queryName] -SubscriptionIds $subscriptionIds
    Export-Object -Name $queryName -Data $rows
}

# ---- Optional: RBAC ----
if ($IncludeRoleAssignments) {
    Write-Host "Exporting role assignments..."
    $roleAssignments = foreach ($s in $subscriptions) {
        Set-AzContext -SubscriptionId $s.Id -TenantId $tenant | Out-Null
        Get-AzRoleAssignment -Scope "/subscriptions/$($s.Id)" |
            Select-Object @{n="subscriptionId";e={$s.Id}},@{n="subscriptionName";e={$s.Name}},
                          DisplayName, SignInName, ObjectType, ObjectId, RoleDefinitionName, Scope
    }
    Export-Object -Name "role-assignments" -Data $roleAssignments
}

# ---- Optional: Policy ----
if ($IncludePolicyAssignments) {
    Write-Host "Exporting policy assignments..."
    $policyAssignments = foreach ($s in $subscriptions) {
        Set-AzContext -SubscriptionId $s.Id -TenantId $tenant | Out-Null
        Get-AzPolicyAssignment -Scope "/subscriptions/$($s.Id)" |
            Select-Object @{n="subscriptionId";e={$s.Id}},@{n="subscriptionName";e={$s.Name}},
                          Name, DisplayName, PolicyDefinitionId, Scope, EnforcementMode
    }
    Export-Object -Name "policy-assignments" -Data $policyAssignments
}

# ---- Optional: VM Insights connections (who-talks-to-who) ----
if ($IncludeVmInsightsConnections -and $haveLA) {
    Write-Host "Querying VM Insights connections from Log Analytics workspaces..."
    $workspaces = Invoke-ResourceGraphQueryAll -SubscriptionIds $subscriptionIds -Query @"
Resources
| where type =~ 'microsoft.operationalinsights/workspaces'
| project subscriptionId, resourceGroup, name, customerId = tostring(properties.customerId), id
"@

    $kql = @"
VMConnection
| where TimeGenerated > ago(${LookbackDays}d)
| summarize Connections = count(), BytesSent = sum(BytesSent), BytesReceived = sum(BytesReceived),
            FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
    by SourceComputerId = Computer, DestinationIp, DestinationPort, Direction, ProcessName
| order by Connections desc
| take 5000
"@

    $allConn = New-Object System.Collections.Generic.List[object]
    foreach ($ws in $workspaces) {
        try {
            $wsId = $ws.customerId
            if (-not $wsId) { continue }
            $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $wsId -Query $kql -ErrorAction Stop
            foreach ($r in $res.Results) {
                $allConn.Add([pscustomobject]@{
                    workspaceName    = $ws.name
                    subscriptionId   = $ws.subscriptionId
                    sourceComputer   = $r.SourceComputerId
                    destinationIp    = $r.DestinationIp
                    destinationPort  = $r.DestinationPort
                    direction        = $r.Direction
                    processName      = $r.ProcessName
                    connections      = $r.Connections
                    bytesSent        = $r.BytesSent
                    bytesReceived    = $r.BytesReceived
                    firstSeen        = $r.FirstSeen
                    lastSeen         = $r.LastSeen
                })
            }
        } catch {
            Write-Warning "  Workspace '$($ws.name)': $($_.Exception.Message)"
        }
    }
    Export-Object -Name "vm-insights-connections" -Data $allConn.ToArray()
}

# ---- Optional: App Insights dependencies (app -> backend) ----
if ($IncludeAppInsightsDependencies -and $haveAI) {
    Write-Host "Querying Application Insights dependencies..."
    $components = Invoke-ResourceGraphQueryAll -SubscriptionIds $subscriptionIds -Query @"
Resources
| where type =~ 'microsoft.insights/components'
| project subscriptionId, resourceGroup, name, appId = tostring(properties.AppId), id
"@

    $depKql = @"
dependencies
| where timestamp > ago(${LookbackDays}d)
| summarize CallCount = count(), AvgDurationMs = avg(duration), FailureCount = countif(success == false)
    by type, target, name
| order by CallCount desc
| take 2000
"@

    $allDeps = New-Object System.Collections.Generic.List[object]
    foreach ($c in $components) {
        try {
            $res = Invoke-AzOperationalInsightsQuery -ErrorAction Stop -Query $depKql -WorkspaceId $c.appId 2>$null
            # App Insights classic query path via REST if the above is unavailable:
            if (-not $res) {
                $body = @{ query = $depKql } | ConvertTo-Json
                $uri  = "https://api.applicationinsights.io/v1/apps/$($c.appId)/query"
                $token = (Get-AzAccessToken -ResourceUrl "https://api.applicationinsights.io").Token
                $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/json" `
                        -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
                $cols = $resp.tables[0].columns.name
                foreach ($row in $resp.tables[0].rows) {
                    $obj = [ordered]@{ appInsightsName = $c.name; subscriptionId = $c.subscriptionId }
                    for ($i=0; $i -lt $cols.Count; $i++) { $obj[$cols[$i]] = $row[$i] }
                    $allDeps.Add([pscustomobject]$obj)
                }
            }
        } catch {
            Write-Warning "  App Insights '$($c.name)': $($_.Exception.Message)"
        }
    }
    Export-Object -Name "app-insights-dependencies" -Data $allDeps.ToArray()
}

# ---- Summary ----
$summary = [pscustomobject]@{
    tenantId          = $tenant
    subscriptionCount = $subscriptions.Count
    outputPath        = (Resolve-Path $OutputPath).Path
    generatedAtUtc    = (Get-Date).ToUniversalTime().ToString("o")
    lookbackDays      = $LookbackDays
    roleAssignments   = [bool]$IncludeRoleAssignments
    policyAssignments = [bool]$IncludePolicyAssignments
    vmInsights        = [bool]$IncludeVmInsightsConnections
    appInsights       = [bool]$IncludeAppInsightsDependencies
}
$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "run-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "Inventory export complete."
Write-Host "Output folder: $((Resolve-Path $OutputPath).Path)"

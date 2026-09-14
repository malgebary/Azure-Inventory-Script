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

.PARAMETER IncludeStorageLinks
Export configured storage relationships (`storage-links`): resources whose
CONFIGURATION points at a storage account -- SQL auditing / vulnerability-assessment
targets, VM boot diagnostics, function/web app storage, diagnostic destinations, etc.
This is a config relationship, not observed traffic. PaaS-internal DB->storage is not
observable and won't appear.

.PARAMETER IncludeDependencies
Convenience switch that enables -IncludeVmInsightsConnections,
-IncludeAppInsightsDependencies, and -IncludeStorageLinks at once.

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
    [switch]$IncludeStorageLinks,
    [switch]$IncludeDependencies,
    [switch]$UseDeviceAuthentication,
    [int]$LookbackDays = 30
)

$ErrorActionPreference = "Stop"

# -IncludeDependencies is a convenience switch that turns on BOTH dependency exports
# plus configured storage links.
if ($IncludeDependencies) {
    $IncludeVmInsightsConnections   = $true
    $IncludeAppInsightsDependencies = $true
    $IncludeStorageLinks            = $true
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
    'microsoft.network/azurefirewalls','microsoft.network/firewallpolicies',
    'microsoft.network/applicationgateways','microsoft.network/frontdoors',
    'microsoft.cdn/profiles','microsoft.network/loadbalancers',
    'microsoft.network/publicipaddresses','microsoft.network/natgateways',
    'microsoft.network/privateendpoints','microsoft.network/privatednszones',
    'microsoft.network/dnsresolvers','microsoft.network/bastionhosts',
    'microsoft.network/ddosprotectionplans','microsoft.network/virtualnetworkgateways',
    'microsoft.network/expressroutecircuits','microsoft.network/connections',
    'microsoft.network/virtualwans','microsoft.network/virtualhubs',
    'microsoft.network/virtualhubs/routeservers','microsoft.network/vpngateways',
    'microsoft.network/expressroutegateways','microsoft.network/p2svpngateways',
    'microsoft.network/applicationgatewaywebapplicationfirewallpolicies',
    'microsoft.network/frontdoorwebapplicationfirewallpolicies')
| project subscriptionId, resourceGroup, name, type, location, tags = tostring(tags), id
| order by subscriptionId, resourceGroup, type, name
"@

  "vnets-subnets" = @"
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets to typeof(dynamic)
| extend seList = subnet.properties.serviceEndpoints
| extend serviceEndpoints = iff(isnull(seList), '', tostring(strcat_array(extract_all(@'"service":"([^"]+)"', tostring(seList)), ', ')))
| extend delegatedService = tostring(subnet.properties.delegations[0].properties.serviceName)
| project subscriptionId, resourceGroup, vnetName = name, location,
          addressPrefixes = tostring(properties.addressSpace.addressPrefixes),
          subnetName = tostring(subnet.name),
          subnetPrefix = tostring(subnet.properties.addressPrefix),
          subnetPrefixes = tostring(subnet.properties.addressPrefixes),
          serviceEndpoints,
          delegatedService,
          isDelegated = isnotempty(delegatedService),
          privateEndpointNetworkPolicies = tostring(subnet.properties.privateEndpointNetworkPolicies),
          privateLinkServiceNetworkPolicies = tostring(subnet.properties.privateLinkServiceNetworkPolicies),
          defaultOutboundAccess = tostring(subnet.properties.defaultOutboundAccess),
          natGatewayId = tostring(subnet.properties.natGateway.id),
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
          sourceAddressPrefixes = tostring(rule.properties.sourceAddressPrefixes),
          sourceApplicationSecurityGroups = tostring(rule.properties.sourceApplicationSecurityGroups),
          sourcePortRange = tostring(rule.properties.sourcePortRange),
          sourcePortRanges = tostring(rule.properties.sourcePortRanges),
          destinationAddressPrefix = tostring(rule.properties.destinationAddressPrefix),
          destinationAddressPrefixes = tostring(rule.properties.destinationAddressPrefixes),
          destinationApplicationSecurityGroups = tostring(rule.properties.destinationApplicationSecurityGroups),
          destinationPortRange = tostring(rule.properties.destinationPortRange),
          destinationPortRanges = tostring(rule.properties.destinationPortRanges),
          id
| order by subscriptionId, resourceGroup, nsgName, priority
"@

  "route-tables" = @"
Resources
| where type =~ 'microsoft.network/routetables'
| extend gatewayRoutePropagation = iff(tobool(properties.disableBgpRoutePropagation) == true, 'Disabled', 'Enabled')
| mv-expand route = properties.routes to typeof(dynamic)
| project subscriptionId, resourceGroup, routeTableName = name, location,
          gatewayRoutePropagation,
          disableBgpRoutePropagation = tostring(properties.disableBgpRoutePropagation),
          routeName = tostring(route.name),
          addressPrefix = tostring(route.properties.addressPrefix),
          nextHopType = tostring(route.properties.nextHopType),
          nextHopIpAddress = tostring(route.properties.nextHopIpAddress),
          id
| order by subscriptionId, resourceGroup, routeTableName, addressPrefix
"@

  "private-endpoints" = @"
Resources
| where type =~ 'microsoft.network/privateendpoints'
| extend conn = coalesce(properties.privateLinkServiceConnections, properties.manualPrivateLinkServiceConnections)
| extend conn0 = conn[0]
| extend targetResourceId = tostring(conn0.properties.privateLinkServiceId)
| extend targetResourceType = tostring(strcat_array(array_slice(split(targetResourceId, '/'), 6, 7), '/'))
| extend groupIds = tostring(conn0.properties.groupIds)
| extend connectionState = tostring(conn0.properties.privateLinkServiceConnectionState.status)
| project subscriptionId, resourceGroup, name, location,
          subnetId = tostring(properties.subnet.id),
          targetResourceId, targetResourceType, groupIds, connectionState,
          id
| order by subscriptionId, resourceGroup, name
"@

  "vnet-connections" = @"
Resources
| where type in~ ('microsoft.network/networkinterfaces','microsoft.network/privateendpoints')
| extend ipcfg = properties.ipConfigurations
| mv-expand ipcfg = iff(type =~ 'microsoft.network/privateendpoints', dynamic([{}]), ipcfg)
| extend subnetId = iff(type =~ 'microsoft.network/privateendpoints', tostring(properties.subnet.id), tostring(ipcfg.properties.subnet.id))
| where isnotempty(subnetId)
| extend connectionType = iff(type =~ 'microsoft.network/privateendpoints', 'PrivateEndpoint', 'NIC')
| extend attachedResource = tostring(name), attachedType = tostring(type), serviceName = ''
| union (
    Resources
    | where type =~ 'microsoft.network/virtualnetworks'
    | mv-expand subnet = properties.subnets
    | extend deleg = subnet.properties.delegations
    | where array_length(deleg) > 0
    | mv-expand deleg
    | extend subnetId = tostring(subnet.id)
    | extend connectionType = 'Delegation', attachedResource = '', attachedType = '',
             serviceName = tostring(deleg.properties.serviceName)
    | extend subscriptionId = subscriptionId, resourceGroup = resourceGroup
)
| extend vnetName = tostring(split(subnetId,'/')[8]), subnetName = tostring(split(subnetId,'/')[10])
| project subscriptionId, resourceGroup, vnetName, subnetName, connectionType,
          attachedResource, attachedType, serviceName, subnetId
| order by subscriptionId, vnetName, subnetName, connectionType, attachedResource
"@

  "network-edge" = @"
Resources
| where type in~ (
    'microsoft.network/virtualnetworkgateways','microsoft.network/expressroutecircuits',
    'microsoft.network/azurefirewalls','microsoft.network/firewallpolicies',
    'microsoft.network/applicationgateways','microsoft.network/frontdoors',
    'microsoft.cdn/profiles','microsoft.network/bastionhosts',
    'microsoft.network/natgateways','microsoft.network/virtualwans',
    'microsoft.network/virtualhubs','microsoft.network/vpngateways',
    'microsoft.network/expressroutegateways','microsoft.network/ddosprotectionplans',
    'microsoft.network/applicationgatewaywebapplicationfirewallpolicies',
    'microsoft.network/frontdoorwebapplicationfirewallpolicies',
    'microsoft.cdn/profiles/securitypolicies')
| extend category = case(
    type =~ 'microsoft.network/virtualnetworkgateways', strcat('VNetGateway:', tostring(properties.gatewayType)),
    type =~ 'microsoft.network/expressroutecircuits', 'ExpressRouteCircuit',
    type =~ 'microsoft.network/azurefirewalls', 'AzureFirewall',
    type =~ 'microsoft.network/firewallpolicies', 'FirewallPolicy',
    type =~ 'microsoft.network/applicationgateways', 'ApplicationGateway',
    type =~ 'microsoft.network/frontdoors', 'FrontDoor(classic)',
    type =~ 'microsoft.cdn/profiles', strcat('FrontDoor/CDN:', tostring(sku.name)),
    type =~ 'microsoft.network/bastionhosts', 'Bastion',
    type =~ 'microsoft.network/natgateways', 'NatGateway',
    type =~ 'microsoft.network/virtualwans', 'VirtualWAN',
    type =~ 'microsoft.network/virtualhubs', 'VirtualHub',
    type =~ 'microsoft.network/vpngateways', 'vWAN-VpnGateway',
    type =~ 'microsoft.network/expressroutegateways', 'vWAN-ExpressRouteGateway',
    type =~ 'microsoft.network/ddosprotectionplans', 'DdosProtectionPlan',
    type =~ 'microsoft.network/applicationgatewaywebapplicationfirewallpolicies', 'WAFPolicy(AppGw)',
    type =~ 'microsoft.network/frontdoorwebapplicationfirewallpolicies', 'WAFPolicy(FrontDoor)',
    type =~ 'microsoft.cdn/profiles/securitypolicies', 'WAFPolicy(FrontDoorStd/Prem)',
    'Other')
| extend gatewayType = tostring(properties.gatewayType)
| extend vpnType = tostring(properties.vpnType)
| extend skuName = coalesce(tostring(properties.sku.name), tostring(sku.name), tostring(properties.sku.tier))
| extend activeActive = tostring(properties.activeActive)
| extend circuitBandwidthMbps = tostring(properties.serviceProviderProperties.bandwidthInMbps)
| extend circuitProvider = tostring(properties.serviceProviderProperties.serviceProviderName)
| extend circuitPeeringLocation = tostring(properties.serviceProviderProperties.peeringLocation)
| extend appGwTier = tostring(properties.sku.tier)
| extend wafEnabled = case(
    type =~ 'microsoft.network/applicationgateways' and isnotempty(tostring(properties.firewallPolicy.id)), 'true (via policy)',
    type =~ 'microsoft.network/applicationgateways', tostring(properties.webApplicationFirewallConfiguration.enabled),
    isnotempty(tostring(properties.policySettings.state)), tostring(properties.policySettings.state),
    '')
| extend wafPolicyId = coalesce(tostring(properties.firewallPolicy.id), tostring(properties.webApplicationFirewallConfiguration.firewallPolicy.id))
| extend wafMode = tostring(properties.policySettings.mode)
| project subscriptionId, resourceGroup, name, type, location, category,
          gatewayType, vpnType, skuName, activeActive,
          circuitProvider, circuitPeeringLocation, circuitBandwidthMbps,
          appGwTier, wafEnabled, wafPolicyId, wafMode, id
| order by subscriptionId, category, name
"@

  "key-vaults" = @"
Resources
| where type =~ 'microsoft.keyvault/vaults'
| project subscriptionId, resourceGroup, name, location,
          enableRbacAuthorization = tostring(properties.enableRbacAuthorization),
          publicNetworkAccess = tostring(properties.publicNetworkAccess), id
| order by subscriptionId, resourceGroup, name
"@

  "key-vault-access" = @"
Resources
| where type =~ 'microsoft.keyvault/vaults'
| extend rbacMode = tostring(properties.enableRbacAuthorization)
| mv-expand ap = properties.accessPolicies
| project subscriptionId, resourceGroup, vaultName = name, location, rbacMode,
          tenantId = tostring(ap.tenantId),
          objectId = tostring(ap.objectId),
          keyPermissions = tostring(ap.permissions.keys),
          secretPermissions = tostring(ap.permissions.secrets),
          certificatePermissions = tostring(ap.permissions.certificates),
          id
| order by subscriptionId, resourceGroup, vaultName
"@

  "key-vault-references" = @"
Resources
| where type !in~ ('microsoft.keyvault/vaults')
| extend p = tostring(properties)
| where p has '.vault.azure.net' or p has '/providers/Microsoft.KeyVault/vaults/'
| extend referencedVaultHost = extract(@'(?i)([a-z0-9-]+)\.vault\.azure\.net', 1, p)
| extend referencedVaultId = extract(@'(?i)(/subscriptions/[^\"]+?/providers/Microsoft\.KeyVault/vaults/[^\"/]+)', 1, p)
| where isnotempty(referencedVaultHost) or isnotempty(referencedVaultId)
| project subscriptionId, resourceGroup, name, type,
          referencedVaultHost, referencedVaultId, id
| order by subscriptionId, resourceGroup, type, name
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

  "storage-accounts" = @"
Resources
| where type =~ 'microsoft.storage/storageaccounts'
| project subscriptionId, resourceGroup, name, location,
          sku = tostring(sku.name), kind,
          accessTier = tostring(properties.accessTier),
          publicNetworkAccess = tostring(properties.publicNetworkAccess),
          allowBlobPublicAccess = tostring(properties.allowBlobPublicAccess),
          supportsHttpsTrafficOnly = tostring(properties.supportsHttpsTrafficOnly),
          minimumTlsVersion = tostring(properties.minimumTlsVersion),
          isHnsEnabled = tostring(properties.isHnsEnabled),
          primaryLocation = tostring(properties.primaryLocation),
          tags = tostring(tags), id
| order by subscriptionId, resourceGroup, name
"@

  "databases" = @"
Resources
| where type in~ (
    'microsoft.sql/servers/databases',
    'microsoft.sql/servers/elasticpools',
    'microsoft.sql/managedinstances',
    'microsoft.sql/managedinstances/databases',
    'microsoft.documentdb/databaseaccounts',
    'microsoft.dbforpostgresql/servers',
    'microsoft.dbforpostgresql/flexibleservers',
    'microsoft.dbformysql/servers',
    'microsoft.dbformysql/flexibleservers',
    'microsoft.dbformariadb/servers',
    'microsoft.cache/redis',
    'microsoft.sqlvirtualmachine/sqlvirtualmachines')
| where type !~ 'microsoft.sql/servers/databases' or name !endswith '/master'
| project subscriptionId, resourceGroup, name, type, location,
          sku = tostring(sku.name), tier = tostring(sku.tier),
          kind,
          publicNetworkAccess = tostring(properties.publicNetworkAccess),
          version = tostring(properties.version),
          tags = tostring(tags), id
| order by subscriptionId, resourceGroup, type, name
"@

  "app-services-and-serverless" = @"
Resources
| where type in~ (
    'microsoft.web/sites',
    'microsoft.web/serverfarms',
    'microsoft.web/staticsites',
    'microsoft.web/hostingenvironments',
    'microsoft.logic/workflows',
    'microsoft.app/containerapps',
    'microsoft.app/managedenvironments',
    'microsoft.apimanagement/service',
    'microsoft.containerregistry/registries',
    'microsoft.containerinstance/containergroups')
| extend appKind = tostring(kind)
| extend appServicePlanId = tostring(properties.serverFarmId)
| project subscriptionId, resourceGroup, name, type, location,
          appKind,
          sku = tostring(sku.name), tier = tostring(sku.tier),
          state = tostring(properties.state),
          httpsOnly = tostring(properties.httpsOnly),
          defaultHostName = tostring(properties.defaultHostName),
          appServicePlanId, tags = tostring(tags), id
| order by subscriptionId, resourceGroup, type, name
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

# ---- Optional: Configured storage links (e.g. DB/VM/app -> storage account) ----
# Surfaces resources whose CONFIGURATION references a storage account: SQL auditing
# and vulnerability-assessment targets, VM boot diagnostics, function/web app storage,
# diagnostic destinations embedded in properties, etc. This is a CONFIG relationship,
# not observed traffic. PaaS-internal DB->storage (e.g. Azure SQL DB internals) is not
# observable and won't appear.
if ($IncludeStorageLinks) {
    Write-Host "Exporting configured storage links..."

    # Pass 1: SQL server/database auditing & vulnerability-assessment storage targets.
    $sqlStorageQuery = @"
Resources
| where type in~ (
    'microsoft.sql/servers/auditingsettings',
    'microsoft.sql/servers/databases/auditingsettings',
    'microsoft.sql/servers/vulnerabilityassessments',
    'microsoft.sql/servers/databases/vulnerabilityassessments',
    'microsoft.sql/servers/extendedauditingsettings',
    'microsoft.sql/servers/databases/extendedauditingsettings')
| extend state = tostring(properties.state)
| extend storageEndpoint = tostring(properties.storageEndpoint)
| extend storageContainerPath = tostring(properties.storageContainerPath)
| where isnotempty(storageEndpoint) or isnotempty(storageContainerPath)
| extend referencedStorageHost = extract(@'(?i)https?://([a-z0-9]+)\.(blob|dfs|file|queue|table)\.', 1, storageEndpoint)
| project subscriptionId, resourceGroup, name, type, source = 'SQL audit/VA config',
          state, referencedStorageHost,
          storageEndpoint, storageContainerPath,
          referencedStorageAccountId = '', id
| order by subscriptionId, resourceGroup, type, name
"@

    # Pass 2: Any resource whose properties reference a storage account
    # (boot diagnostics, function/web app storage, automation, diagnostic destinations,
    # Event Grid system topics, etc.). Excludes storage accounts referencing themselves.
    $genericStorageQuery = @"
Resources
| where type !in~ ('microsoft.storage/storageaccounts')
| extend p = tostring(properties)
| where p has 'core.windows.net' or p has '/providers/Microsoft.Storage/storageAccounts/'
| extend referencedStorageHost = extract(@'(?i)([a-z0-9]+)\.(blob|dfs|file|queue|table)\.core\.windows\.net', 1, p)
| extend referencedStorageAccountId = extract(@'(?i)(/subscriptions/[^\"]+?/providers/Microsoft\.Storage/storageAccounts/[^\"/]+)', 1, p)
| where isnotempty(referencedStorageHost) or isnotempty(referencedStorageAccountId)
| project subscriptionId, resourceGroup, name, type, source = 'referenced in resource properties',
          state = '', referencedStorageHost,
          storageEndpoint = '', storageContainerPath = '',
          referencedStorageAccountId, id
| order by subscriptionId, resourceGroup, type, name
"@

    $storageLinks = New-Object System.Collections.Generic.List[object]
    foreach ($row in (Invoke-ResourceGraphQueryAll -Query $sqlStorageQuery     -SubscriptionIds $subscriptionIds)) { $storageLinks.Add($row) }
    foreach ($row in (Invoke-ResourceGraphQueryAll -Query $genericStorageQuery -SubscriptionIds $subscriptionIds)) { $storageLinks.Add($row) }
    Export-Object -Name "storage-links" -Data $storageLinks.ToArray()
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

# ---- Completeness reconciliation (always runs) ----
# Proves nothing is missed: compares the authoritative per-type resource counts from
# Azure Resource Graph against what the export captured, and flags every resource type
# that only lands in the catch-all resources.csv (i.e. has no dedicated sheet).
Write-Host "Building completeness reconciliation..."

# Map resource TYPE (lowercase) -> the dedicated sheet that captures it.
$typeToSheet = @{}
'microsoft.storage/storageaccounts' | ForEach-Object { $typeToSheet[$_] = 'storage-accounts' }
@(
    'microsoft.sql/servers/databases','microsoft.sql/servers/elasticpools',
    'microsoft.sql/managedinstances','microsoft.sql/managedinstances/databases',
    'microsoft.documentdb/databaseaccounts','microsoft.dbforpostgresql/servers',
    'microsoft.dbforpostgresql/flexibleservers','microsoft.dbformysql/servers',
    'microsoft.dbformysql/flexibleservers','microsoft.dbformariadb/servers',
    'microsoft.cache/redis','microsoft.sqlvirtualmachine/sqlvirtualmachines'
) | ForEach-Object { $typeToSheet[$_] = 'databases' }
@(
    'microsoft.web/sites','microsoft.web/serverfarms','microsoft.web/staticsites',
    'microsoft.web/hostingenvironments','microsoft.logic/workflows',
    'microsoft.app/containerapps','microsoft.app/managedenvironments',
    'microsoft.apimanagement/service','microsoft.containerregistry/registries',
    'microsoft.containerinstance/containergroups'
) | ForEach-Object { $typeToSheet[$_] = 'app-services-and-serverless' }
$typeToSheet['microsoft.compute/virtualmachines'] = 'virtual-machines'
$typeToSheet['microsoft.compute/disks'] = 'disks'
@(
    'microsoft.network/virtualnetworks','microsoft.network/networkinterfaces',
    'microsoft.network/networksecuritygroups','microsoft.network/routetables',
    'microsoft.network/azurefirewalls','microsoft.network/applicationgateways',
    'microsoft.network/loadbalancers','microsoft.network/publicipaddresses',
    'microsoft.network/privateendpoints','microsoft.network/privatednszones',
    'microsoft.network/virtualnetworkgateways','microsoft.network/expressroutecircuits',
    'microsoft.network/connections'
) | ForEach-Object { $typeToSheet[$_] = 'networking' }
$typeToSheet['microsoft.keyvault/vaults'] = 'key-vaults'
$typeToSheet['microsoft.operationalinsights/workspaces'] = 'log-analytics-workspaces'
$typeToSheet['microsoft.insights/components'] = 'app-insights-components'

# Authoritative per-type counts straight from Resource Graph.
$typeCounts = Invoke-ResourceGraphQueryAll -SubscriptionIds $subscriptionIds -Query @"
Resources
| summarize resourceCount = count() by type
| order by resourceCount desc
"@

$reconciliation = foreach ($row in $typeCounts) {
    $t = ([string]$row.type).ToLower()
    $sheet = if ($typeToSheet.ContainsKey($t)) { $typeToSheet[$t] } else { '' }
    [pscustomobject]@{
        type              = $row.type
        resourceCount     = $row.resourceCount
        capturedInSheet   = if ($sheet) { $sheet } else { 'resources (catch-all only)' }
        hasDedicatedSheet = [bool]$sheet
    }
}
$reconciliation = @($reconciliation) | Sort-Object -Property @{e={$_.hasDedicatedSheet}}, @{e={$_.resourceCount};Descending=$true}
Export-Object -Name "completeness-reconciliation" -Data $reconciliation

# Totals + integrity check: does resources.csv hold exactly what Resource Graph reports?
$totalResources     = ($typeCounts | Measure-Object -Property resourceCount -Sum).Sum
$resourcesCsvPath    = Join-Path $OutputPath "resources.csv"
$resourcesCsvCount   = if (Test-Path $resourcesCsvPath) { @(Import-Csv $resourcesCsvPath).Count } else { 0 }
$catchAllOnlyTypes   = @($reconciliation | Where-Object { -not $_.hasDedicatedSheet })
$catchAllOnlyCount   = ($catchAllOnlyTypes | Measure-Object -Property resourceCount -Sum).Sum

$completeness = [pscustomobject]@{
    totalResourceTypes        = @($typeCounts).Count
    totalResources            = $totalResources
    resourcesCsvRowCount      = $resourcesCsvCount
    countsReconcile           = ($totalResources -eq $resourcesCsvCount)
    typesWithDedicatedSheet   = @($reconciliation | Where-Object hasDedicatedSheet).Count
    typesCatchAllOnly         = $catchAllOnlyTypes.Count
    resourcesCatchAllOnly     = [int]$catchAllOnlyCount
    note                      = "Every resource is in resources.csv. 'Catch-all only' types have no dedicated sheet but are fully present in resources.csv. If countsReconcile is true, resources.csv matches the Resource Graph total exactly."
}
$completeness | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "completeness-summary.json") -Encoding UTF8

Write-Host ("  Total resources: {0} across {1} types  (resources.csv rows: {2}, reconcile: {3})" -f `
    $totalResources, @($typeCounts).Count, $resourcesCsvCount, $completeness.countsReconcile)
if (-not $completeness.countsReconcile) {
    Write-Warning "  resources.csv row count does not match the Resource Graph total. Review completeness-reconciliation.csv."
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
    storageLinks      = [bool]$IncludeStorageLinks
    totalResources    = $totalResources
    countsReconcile   = $completeness.countsReconcile
}
$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "run-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "Inventory export complete."
Write-Host "Output folder: $((Resolve-Path $OutputPath).Path)"

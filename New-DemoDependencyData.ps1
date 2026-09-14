<#
.SYNOPSIS
Generates DEMO sample output for AzureA2AInventory.ps1 using fabricated data.

.DESCRIPTION
Your test environment may not have VM Insights or Application Insights enabled,
so the real script can't produce dependency data there. This generator writes
realistic, FABRICATED sample files in the same shape the real script emits, so
you can preview exactly what the customer will see for:

  - vm-insights-connections   (VM-to-VM / server "who talks to who")
  - app-insights-dependencies (app -> SQL / HTTP / storage backend calls)
  - role-assignments          (RBAC: who has what, with principal ObjectIds)
  - managed-identities        (principal IDs)
  - virtual-machines          (context to correlate connection endpoints)
  - vnet-peerings             (structural connectivity context)
  - storage-accounts          (storage inventory with config)
  - databases                 (SQL / Cosmos / PostgreSQL / Redis)
  - app-services-and-serverless (web apps, functions, logic apps, container apps, ACR)
  - key-vault-access          (who can access each vault)
  - key-vault-references      (what resources depend on each vault)
  - completeness-reconciliation + completeness-summary.json (the "capturing everything" proof)

NONE of this is real. It is safe to commit and safe to share as an example.
It does NOT connect to Azure and requires no permissions or modules.

.EXAMPLE
.\New-DemoDependencyData.ps1
.\New-DemoDependencyData.ps1 -OutputPath .\sample-output
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\sample-output"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

function Export-Demo {
    param([object[]]$Data, [string]$Name)
    $Data | Export-Csv -Path (Join-Path $OutputPath "$Name.csv") -NoTypeInformation -Encoding UTF8
    $Data | ConvertTo-Json -Depth 20 | Out-File -FilePath (Join-Path $OutputPath "$Name.json") -Encoding UTF8
    Write-Host ("  {0,-30} {1,4} rows" -f $Name, @($Data).Count)
}

# Stable fake IDs so the sample looks consistent across the files
$subId = "11111111-1111-1111-1111-111111111111"
function New-Guid5 { param([int]$seed) $g = [guid]::NewGuid().ToString(); return $g }

Write-Host "Generating demo sample output in: $OutputPath"

# ---- virtual-machines (context) ----
$vms = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";  name="vm-web-01";  location="eastus"; vmSize="Standard_D4s_v5"; osType="Windows"; powerState="VM running"; licenseType="Windows_Server"; zones="1"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Compute/virtualMachines/vm-web-01" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";  name="vm-web-02";  location="eastus"; vmSize="Standard_D4s_v5"; osType="Windows"; powerState="VM running"; licenseType="Windows_Server"; zones="2"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Compute/virtualMachines/vm-web-02" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";  name="vm-app-01";  location="eastus"; vmSize="Standard_D8s_v5"; osType="Linux";   powerState="VM running"; licenseType="";               zones="1"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Compute/virtualMachines/vm-app-01" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="vm-sql-01";  location="eastus"; vmSize="Standard_E8s_v5"; osType="Windows"; powerState="VM running"; licenseType="Windows_Server"; zones="1"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.Compute/virtualMachines/vm-sql-01" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-infra";     name="vm-dc-01";   location="eastus"; vmSize="Standard_D2s_v5"; osType="Windows"; powerState="VM running"; licenseType="Windows_Server"; zones="1"; id="/subscriptions/$subId/resourceGroups/rg-infra/providers/Microsoft.Compute/virtualMachines/vm-dc-01" }
)
Export-Demo -Name "virtual-machines" -Data $vms

# ---- vm-insights-connections (the star of the show for the customer) ----
# Models a 3-tier app: web -> app -> sql, plus DC (LDAP/Kerberos/DNS) dependencies.
$now = (Get-Date).ToUniversalTime()
$first = $now.AddDays(-30).ToString("o")
$last  = $now.ToString("o")
$conns = @(
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-web-01"; destinationIp="10.10.2.10"; destinationPort=8080; direction="outbound"; processName="w3wp.exe";    connections=48213; bytesSent=1820394112; bytesReceived=5502398112; firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-web-02"; destinationIp="10.10.2.10"; destinationPort=8080; direction="outbound"; processName="w3wp.exe";    connections=47110; bytesSent=1790112044; bytesReceived=5410221904; firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-app-01"; destinationIp="10.10.3.20"; destinationPort=1433; direction="outbound"; processName="java";        connections=90412; bytesSent=980221104;  bytesReceived=44102338910; firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-web-01"; destinationIp="10.10.1.5";  destinationPort=53;   direction="outbound"; processName="svchost.exe"; connections=12203; bytesSent=2210432;    bytesReceived=3120933;    firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-app-01"; destinationIp="10.10.1.5";  destinationPort=389;  direction="outbound"; processName="ldap";        connections=8109;  bytesSent=1220432;    bytesReceived=2120933;    firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-app-01"; destinationIp="10.10.1.5";  destinationPort=88;   direction="outbound"; processName="lsass.exe";   connections=6410;  bytesSent=920432;     bytesReceived=1120933;    firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-sql-01"; destinationIp="10.10.1.5";  destinationPort=88;   direction="outbound"; processName="lsass.exe";   connections=5122;  bytesSent=812433;     bytesReceived=1020933;    firstSeen=$first; lastSeen=$last }
    [pscustomobject]@{ workspaceName="law-monitoring-prod"; subscriptionId=$subId; sourceComputer="vm-web-01"; destinationIp="52.168.10.44"; destinationPort=443; direction="outbound"; processName="w3wp.exe";  connections=21044; bytesSent=410220112;  bytesReceived=1802204410; firstSeen=$first; lastSeen=$last }
)
Export-Demo -Name "vm-insights-connections" -Data $conns

# ---- app-insights-dependencies (app -> backend calls) ----
$deps = @(
    [pscustomobject]@{ appInsightsName="ai-storefront-prod"; subscriptionId=$subId; type="SQL";        target="vm-sql-01 | StorefrontDb"; name="SELECT Orders";        CallCount=182044; AvgDurationMs=14.2;  FailureCount=142 }
    [pscustomobject]@{ appInsightsName="ai-storefront-prod"; subscriptionId=$subId; type="HTTP";       target="api.payments.contoso.com"; name="POST /v1/charge";     CallCount=40122;  AvgDurationMs=210.7; FailureCount=88 }
    [pscustomobject]@{ appInsightsName="ai-storefront-prod"; subscriptionId=$subId; type="Azure blob"; target="stprodassets.blob.core.windows.net"; name="GET /images"; CallCount=98210;  AvgDurationMs=32.1;  FailureCount=12 }
    [pscustomobject]@{ appInsightsName="ai-storefront-prod"; subscriptionId=$subId; type="Azure Service Bus"; target="sb-prod.servicebus.windows.net"; name="Send orders-queue"; CallCount=40118; AvgDurationMs=9.8; FailureCount=3 }
    [pscustomobject]@{ appInsightsName="ai-identity-prod";   subscriptionId=$subId; type="HTTP";       target="login.microsoftonline.com"; name="POST /token";       CallCount=15903;  AvgDurationMs=88.4;  FailureCount=21 }
    [pscustomobject]@{ appInsightsName="ai-identity-prod";   subscriptionId=$subId; type="Azure Key Vault"; target="kv-prod.vault.azure.net"; name="GET /secrets";      CallCount=22011;  AvgDurationMs=41.9;  FailureCount=0 }
)
Export-Demo -Name "app-insights-dependencies" -Data $deps

# ---- role-assignments (RBAC with principal ObjectIds) ----
$roles = @(
    [pscustomobject]@{ subscriptionId=$subId; subscriptionName="Prod-Landing-Zone"; DisplayName="Cloud Platform Team";  SignInName="";                          ObjectType="Group";           ObjectId="a1b2c3d4-0001-4000-8000-000000000001"; RoleDefinitionName="Owner";        Scope="/subscriptions/$subId" }
    [pscustomobject]@{ subscriptionId=$subId; subscriptionName="Prod-Landing-Zone"; DisplayName="Jane Admin";           SignInName="jane.admin@contoso.com";    ObjectType="User";            ObjectId="a1b2c3d4-0001-4000-8000-000000000002"; RoleDefinitionName="Contributor";  Scope="/subscriptions/$subId/resourceGroups/rg-app-prod" }
    [pscustomobject]@{ subscriptionId=$subId; subscriptionName="Prod-Landing-Zone"; DisplayName="Reader-Auditors";      SignInName="";                          ObjectType="Group";           ObjectId="a1b2c3d4-0001-4000-8000-000000000003"; RoleDefinitionName="Reader";       Scope="/subscriptions/$subId" }
    [pscustomobject]@{ subscriptionId=$subId; subscriptionName="Prod-Landing-Zone"; DisplayName="id-storefront-app";    SignInName="";                          ObjectType="ServicePrincipal"; ObjectId="a1b2c3d4-0001-4000-8000-000000000004"; RoleDefinitionName="Key Vault Secrets User"; Scope="/subscriptions/$subId/resourceGroups/rg-app-prod" }
    [pscustomobject]@{ subscriptionId=$subId; subscriptionName="Prod-Landing-Zone"; DisplayName="CSP-Partner-Admins";   SignInName="";                          ObjectType="ForeignGroup";     ObjectId="a1b2c3d4-0001-4000-8000-000000000005"; RoleDefinitionName="Owner";        Scope="/subscriptions/$subId" }
)
Export-Demo -Name "role-assignments" -Data $roles

# ---- managed-identities (principal IDs) ----
$mi = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="vm-app-01";        type="microsoft.compute/virtualmachines"; location="eastus"; identityType="SystemAssigned"; principalId="b2c3d4e5-0002-4000-8000-000000000001"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Compute/virtualMachines/vm-app-01" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="id-storefront-app"; type="microsoft.managedidentity/userassignedidentities"; location="eastus"; identityType="UserAssigned"; principalId="b2c3d4e5-0002-4000-8000-000000000002"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-storefront-app" }
)
Export-Demo -Name "managed-identities" -Data $mi

# ---- vnet-peerings (structural connectivity context) ----
$peer = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-network-hub"; localVnet="vnet-hub"; location="eastus"; peeringName="hub-to-app"; peeringState="Connected"; remoteVnetId="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Network/virtualNetworks/vnet-app"; allowForwardedTraffic="True"; allowGatewayTransit="True"; useRemoteGateways="False"; id="peer1" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";    localVnet="vnet-app"; location="eastus"; peeringName="app-to-hub"; peeringState="Connected"; remoteVnetId="/subscriptions/$subId/resourceGroups/rg-network-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"; allowForwardedTraffic="False"; allowGatewayTransit="False"; useRemoteGateways="True"; id="peer2" }
)
Export-Demo -Name "vnet-peerings" -Data $peer

# ---- key-vault-access (who can access each vault) ----
$kvAccess = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-security"; vaultName="kv-prod"; location="eastus"; rbacMode="false"; tenantId="22222222-2222-2222-2222-222222222222"; objectId="a1b2c3d4-0001-4000-8000-000000000004"; keyPermissions="[""get"",""wrapKey"",""unwrapKey""]"; secretPermissions="[""get"",""list""]"; certificatePermissions="[]"; id="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-security"; vaultName="kv-prod"; location="eastus"; rbacMode="false"; tenantId="22222222-2222-2222-2222-222222222222"; objectId="b2c3d4e5-0002-4000-8000-000000000002"; keyPermissions="[]"; secretPermissions="[""get""]"; certificatePermissions="[]"; id="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-security"; vaultName="kv-cmk";  location="eastus"; rbacMode="true";  tenantId="22222222-2222-2222-2222-222222222222"; objectId="";                                   keyPermissions="";               secretPermissions="";           certificatePermissions="";   id="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-cmk" }
)
Export-Demo -Name "key-vault-access" -Data $kvAccess

# ---- key-vault-references (what depends on each vault) ----
$kvRefs = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="app-storefront"; type="microsoft.web/sites";                  referencedVaultHost="kv-prod"; referencedVaultId="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-prod"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/sites/app-storefront" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="ca-api";         type="microsoft.app/containerapps";        referencedVaultHost="kv-prod"; referencedVaultId="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-prod"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.App/containerApps/ca-api" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="des-prod";      type="microsoft.compute/diskencryptionsets"; referencedVaultHost="kv-cmk"; referencedVaultId="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-cmk"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.Compute/diskEncryptionSets/des-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-security"; name="pe-kv";          type="microsoft.network/privateendpoints"; referencedVaultHost="kv-prod"; referencedVaultId="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-prod"; id="/subscriptions/$subId/resourceGroups/rg-security/providers/Microsoft.Network/privateEndpoints/pe-kv" }
)
Export-Demo -Name "key-vault-references" -Data $kvRefs

# ---- storage-accounts ----
$storage = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";  name="stprodassets";   location="eastus"; sku="Standard_LRS"; kind="StorageV2"; accessTier="Hot";  publicNetworkAccess="Disabled"; allowBlobPublicAccess="false"; supportsHttpsTrafficOnly="true"; minimumTlsVersion="TLS1_2"; isHnsEnabled="false"; primaryLocation="eastus"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Storage/storageAccounts/stprodassets" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="stprodbackups";  location="eastus"; sku="Standard_GRS"; kind="StorageV2"; accessTier="Cool"; publicNetworkAccess="Disabled"; allowBlobPublicAccess="false"; supportsHttpsTrafficOnly="true"; minimumTlsVersion="TLS1_2"; isHnsEnabled="false"; primaryLocation="eastus"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.Storage/storageAccounts/stprodbackups" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="stdatalakeprod"; location="eastus"; sku="Standard_ZRS"; kind="StorageV2"; accessTier="Hot";  publicNetworkAccess="Enabled";  allowBlobPublicAccess="false"; supportsHttpsTrafficOnly="true"; minimumTlsVersion="TLS1_2"; isHnsEnabled="true";  primaryLocation="eastus"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.Storage/storageAccounts/stdatalakeprod" }
)
Export-Demo -Name "storage-accounts" -Data $storage

# ---- databases ----
$databases = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="sql-prod/StorefrontDb"; type="microsoft.sql/servers/databases";        location="eastus"; sku="S3";           tier="Standard";      kind="v12.0,user"; publicNetworkAccess="Disabled"; version=""; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.Sql/servers/sql-prod/databases/StorefrontDb" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="cosmos-prod";           type="microsoft.documentdb/databaseaccounts";     location="eastus"; sku="";             tier="";              kind="GlobalDocumentDB"; publicNetworkAccess="Disabled"; version=""; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-data-prod"; name="pg-prod";               type="microsoft.dbforpostgresql/flexibleservers"; location="eastus"; sku="Standard_D4s_v3"; tier="GeneralPurpose"; kind="";           publicNetworkAccess="Disabled"; version="15"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-data-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod";  name="redis-prod";            type="microsoft.cache/redis";                     location="eastus"; sku="Standard";     tier="";              kind="";           publicNetworkAccess="Disabled"; version=""; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Cache/Redis/redis-prod" }
)
Export-Demo -Name "databases" -Data $databases

# ---- app-services-and-serverless ----
$apps = @(
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="app-storefront";  type="microsoft.web/sites";               location="eastus"; appKind="app,linux";      sku="P1v3"; tier="PremiumV3"; state="Running"; httpsOnly="true"; defaultHostName="app-storefront.azurewebsites.net"; appServicePlanId="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/serverfarms/plan-prod"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/sites/app-storefront" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="func-orders";     type="microsoft.web/sites";               location="eastus"; appKind="functionapp";    sku="Y1";   tier="Dynamic";   state="Running"; httpsOnly="true"; defaultHostName="func-orders.azurewebsites.net";    appServicePlanId="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/serverfarms/plan-func"; tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/sites/func-orders" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="plan-prod";       type="microsoft.web/serverfarms";         location="eastus"; appKind="linux";          sku="P1v3"; tier="PremiumV3"; state="";        httpsOnly="";     defaultHostName="";                                 appServicePlanId="";                                                                                                             tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Web/serverfarms/plan-prod" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="logic-notify";    type="microsoft.logic/workflows";         location="eastus"; appKind="";               sku="";     tier="";          state="Enabled"; httpsOnly="";     defaultHostName="";                                 appServicePlanId="";                                                                                                             tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.Logic/workflows/logic-notify" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="ca-api";          type="microsoft.app/containerapps";       location="eastus"; appKind="";               sku="";     tier="";          state="";        httpsOnly="";     defaultHostName="ca-api.happysky.eastus.azurecontainerapps.io"; appServicePlanId="";                                                                                     tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.App/containerApps/ca-api" }
    [pscustomobject]@{ subscriptionId=$subId; resourceGroup="rg-app-prod"; name="acrprod";         type="microsoft.containerregistry/registries"; location="eastus"; appKind="";          sku="Premium"; tier="";       state="";        httpsOnly="";     defaultHostName="";                                 appServicePlanId="";                                                                                                             tags="{}"; id="/subscriptions/$subId/resourceGroups/rg-app-prod/providers/Microsoft.ContainerRegistry/registries/acrprod" }
)
Export-Demo -Name "app-services-and-serverless" -Data $apps

# ---- completeness-reconciliation (the "capturing everything" proof) ----
# Shows dedicated-sheet types alongside catch-all-only types that are easy to miss.
$recon = @(
    [pscustomobject]@{ type="microsoft.network/privatednszones/virtualnetworklinks"; resourceCount=37; capturedInSheet="resources (catch-all only)"; hasDedicatedSheet=$false }
    [pscustomobject]@{ type="microsoft.compute/virtualmachines/extensions";          resourceCount=8;  capturedInSheet="resources (catch-all only)"; hasDedicatedSheet=$false }
    [pscustomobject]@{ type="microsoft.network/networkwatchers";                      resourceCount=3;  capturedInSheet="resources (catch-all only)"; hasDedicatedSheet=$false }
    [pscustomobject]@{ type="microsoft.insights/actiongroups";                        resourceCount=2;  capturedInSheet="resources (catch-all only)"; hasDedicatedSheet=$false }
    [pscustomobject]@{ type="microsoft.network/networksecuritygroups";                resourceCount=6;  capturedInSheet="networking";                  hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.network/virtualnetworks";                      resourceCount=4;  capturedInSheet="networking";                  hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.storage/storageaccounts";                      resourceCount=3;  capturedInSheet="storage-accounts";            hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.web/sites";                                    resourceCount=2;  capturedInSheet="app-services-and-serverless"; hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.sql/servers/databases";                        resourceCount=1;  capturedInSheet="databases";                   hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.compute/virtualmachines";                      resourceCount=5;  capturedInSheet="virtual-machines";            hasDedicatedSheet=$true }
    [pscustomobject]@{ type="microsoft.keyvault/vaults";                              resourceCount=2;  capturedInSheet="key-vaults";                  hasDedicatedSheet=$true }
)
Export-Demo -Name "completeness-reconciliation" -Data $recon

$totalDemo = ($recon | Measure-Object -Property resourceCount -Sum).Sum
[pscustomobject]@{
    totalResourceTypes      = $recon.Count
    totalResources          = $totalDemo
    resourcesCsvRowCount    = $totalDemo
    countsReconcile         = $true
    typesWithDedicatedSheet = @($recon | Where-Object hasDedicatedSheet).Count
    typesCatchAllOnly       = @($recon | Where-Object { -not $_.hasDedicatedSheet }).Count
    resourcesCatchAllOnly   = ($recon | Where-Object { -not $_.hasDedicatedSheet } | Measure-Object resourceCount -Sum).Sum
    note                    = "FABRICATED DEMO. Every resource is in resources.csv. countsReconcile=true means resources.csv matches the Resource Graph total exactly."
} | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "completeness-summary.json") -Encoding UTF8
Write-Host ("  {0,-30} {1,4} rows" -f "completeness-summary.json", 1)

# ---- run summary marker ----
[pscustomobject]@{
    note           = "FABRICATED DEMO DATA - not from any real Azure environment"
    generatedAtUtc = $now.ToString("o")
    scenario       = "3-tier app (web->app->sql) with DC dependencies, plus app-tier backend calls"
} | ConvertTo-Json | Out-File -FilePath (Join-Path $OutputPath "DEMO-README.json") -Encoding UTF8

Write-Host ""
Write-Host "Demo output written to: $((Resolve-Path $OutputPath).Path)"
Write-Host "These files mirror the real script's output shape. Data is fabricated."

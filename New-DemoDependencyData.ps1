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

# ---- run summary marker ----
[pscustomobject]@{
    note           = "FABRICATED DEMO DATA - not from any real Azure environment"
    generatedAtUtc = $now.ToString("o")
    scenario       = "3-tier app (web->app->sql) with DC dependencies, plus app-tier backend calls"
} | ConvertTo-Json | Out-File -FilePath (Join-Path $OutputPath "DEMO-README.json") -Encoding UTF8

Write-Host ""
Write-Host "Demo output written to: $((Resolve-Path $OutputPath).Path)"
Write-Host "These files mirror the real script's output shape. Data is fabricated."

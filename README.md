# Azure Inventory & Dependency Export

A **read-only** PowerShell script that inventories an entire Azure tenant and
(optionally) exports application and network **dependencies** — designed to prepare
for an **Azure-to-Azure move** (tenant/subscription consolidation, CSP→EA, or
landing-zone re-platforming).

It does **not** install any agents, does **not** modify resources, and only reads
metadata plus (optionally) monitoring data that is **already being collected** by
VM Insights and Application Insights.

---

## What it collects

Every run produces a timestamped folder (`azure-a2a-inventory-<date>-<time>`) with
one **CSV + JSON** file per dataset:

| File | What it contains |
| --- | --- |
| `management-groups`, `management-group-hierarchy` | Management group tree |
| `subscriptions` | All enabled subscriptions in the tenant |
| `resource-groups` | Every resource group |
| `resources` | Every resource (name, type, location, SKU, tags) |
| `resource-summary-by-type` | Resource counts by type per subscription |
| `virtual-machines`, `disks` | VM size/OS/power state/license; disk SKU/size |
| `networking` | VNets, NICs, NSGs, route tables, firewalls, gateways, ER circuits, public IPs |
| `vnets-subnets` | VNet address spaces and subnets |
| `vnet-peerings` | **Structural connectivity** — which VNet connects to which |
| `nsg-rules` | Every NSG rule (allowed/denied paths) |
| `private-endpoints` | Private endpoints and what they connect to |
| `key-vaults` | Vaults, RBAC mode, public network access |
| `managed-identities` | System/user-assigned identities + **principal IDs** |
| `log-analytics-workspaces`, `app-insights-components` | Monitoring footprint (discovery) |
| `role-assignments` *(optional)* | **RBAC** — who has what, with principal ObjectIds |
| `policy-assignments` *(optional)* | Azure Policy assignments |
| `vm-insights-connections` *(optional)* | **VM-to-VM traffic** — server "who talks to who" |
| `app-insights-dependencies` *(optional)* | **App → backend calls** (SQL, HTTP, storage, queues) |

---

## Prerequisites

- **PowerShell 7+** (recommended)
- Azure PowerShell modules:

```powershell
Install-Module Az.Accounts, Az.ResourceGraph, Az.Resources, Az.OperationalInsights, Az.ApplicationInsights -Scope CurrentUser
```

---

## Permissions required

| Capability | Minimum permission |
| --- | --- |
| Resource / network / VM inventory | **Reader** on the target subscriptions (or the root management group) |
| Management group hierarchy | **Management Group Reader** |
| Role assignments (`-IncludeRoleAssignments`) | `Microsoft.Authorization/roleAssignments/read` (Reader usually covers it) |
| Policy assignments (`-IncludePolicyAssignments`) | **Reader** |
| VM Insights connections (`-IncludeVmInsightsConnections`) | **Log Analytics Reader** on the workspaces |
| App Insights dependencies (`-IncludeAppInsightsDependencies`) | **Monitoring Reader** on the App Insights components |

> **Tip:** Assigning **Reader on the tenant root management group** is the cleanest way
> to guarantee the script sees every current and future subscription in one run.

---

## How to run

### 1. Sign in

The script signs you in automatically. If the interactive browser popup crashes your
terminal (a known issue in some VS Code / WAM setups), use **device-code auth** with
the `-UseDeviceAuthentication` switch — it prints a URL + code instead of a popup.

### 2. Basic inventory

```powershell
cd "path\to\Azure-Inventory-Script"
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>" -UseDeviceAuthentication
```

### 3. Inventory + RBAC + policy

```powershell
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>" -UseDeviceAuthentication `
    -IncludeRoleAssignments -IncludePolicyAssignments
```

### 4. Inventory + **dependencies** (the full picture)

```powershell
.\AzureA2AInventory.ps1 -TenantId "<tenant-guid>" -UseDeviceAuthentication `
    -IncludeDependencies -LookbackDays 30
```

`-IncludeDependencies` is a convenience switch that turns on **both**
`-IncludeVmInsightsConnections` and `-IncludeAppInsightsDependencies`. You can also
pass either one individually.

### Don't know your tenant ID?

Sign in first and let your account tell you which tenant/subscriptions it can reach:

```powershell
Connect-AzAccount -UseDeviceAuthentication
Get-AzContext     | Select-Object @{n='Account';e={$_.Account.Id}}, @{n='TenantId';e={$_.Tenant.Id}}
Get-AzSubscription | Select-Object Name, Id, TenantId, State
```

### All parameters

| Parameter | Description |
| --- | --- |
| `-TenantId` | Tenant to sign into. If omitted, uses the account's default tenant. |
| `-OutputPath` | Output folder. Defaults to `.\azure-a2a-inventory-<timestamp>`. |
| `-UseDeviceAuthentication` | Device-code sign-in (URL + code) instead of the browser popup. |
| `-IncludeRoleAssignments` | Also export RBAC role assignments. |
| `-IncludePolicyAssignments` | Also export Azure Policy assignments. |
| `-IncludeVmInsightsConnections` | Export VM-to-VM traffic from VM Insights. |
| `-IncludeAppInsightsDependencies` | Export app→backend calls from Application Insights. |
| `-IncludeDependencies` | Convenience switch: enables **both** dependency exports. |
| `-LookbackDays` | Days of monitoring data to pull for dependencies. Default `30`. |

---

## Multiple tenants (e.g. CSP subs + your own subs)

The boundary that matters is the **Entra tenant**, not the billing model. CSP-billed and
customer-billed subscriptions in the **same tenant** are captured in one run. If your
subscriptions span **multiple tenants**, run the script once per tenant with a different
`-TenantId` — each run writes its own timestamped folder, so nothing is overwritten.

---

## Understanding the dependency output

The `sample-output/` folder contains **fabricated example data** (safe to read, not from
any real environment) so you can see the exact shape of the reports. See
[`sample-output/README.md`](sample-output/README.md) for a full walkthrough.

### App dependencies — `app-insights-dependencies.csv`

Each row is **one type of outbound call an application makes to a backend**:

| Column | Meaning |
| --- | --- |
| `appInsightsName` | Which app is making the call |
| `type` | Kind of dependency: `SQL`, `HTTP`, `Azure blob`, `Azure Service Bus`, `Azure Key Vault`, ... |
| `target` | The specific thing it calls (DB, endpoint, storage account, queue) |
| `name` | The specific operation (`SELECT Orders`, `POST /v1/charge`) |
| `CallCount` | How many times in the window — higher = tighter coupling |
| `AvgDurationMs` | Average latency (slow dependencies = migration risk) |
| `FailureCount` | Failures (reliability signal) |

**Example reading:** an app with a heavy `SQL` dependency on `StorefrontDb`, an external
`HTTP` call to a payments API, a `blob` storage account, and a `Service Bus` queue
**cannot be moved alone** — everything it depends on must move together (or be
reachable). That is exactly how you build **migration waves**.

### Network dependencies — `vm-insights-connections.csv`

Each row is an **observed connection** from one VM to a destination IP/port/process
(e.g. web → app on `8080`, app → SQL on `1433`, plus DC dependencies like DNS `53`,
LDAP `389`, Kerberos `88`). Correlate destination IPs back to `virtual-machines.csv` /
`networking.csv` to name both ends.

---

## Coverage & limitations (read this)

- **Dependencies rely on monitoring that is already enabled.** The script only *reads*
  existing VM Insights and Application Insights data — it does not turn anything on.
  Workloads without that monitoring **will not appear**, which is itself a useful gap
  to flag.
- **Structural connectivity is always available** (VNet peerings, NSG rules, private
  endpoints) with no agents. For observed network flows **without in-guest agents**,
  consider **NSG/VNet Flow Logs + Traffic Analytics** as a complement.
- **Azure Migrate is not used here.** The Azure Migrate appliance and its agentless
  dependency analysis are for **on-premises / other-cloud** sources — not for mapping
  VMs already running in Azure. For Azure-native workloads, VM Insights, App Insights,
  and flow logs are the right tools.

---

## Your data stays local

**Running this script does not send your information anywhere.** When you run it, the
results are written **only to a folder on the machine you run it from**
(`azure-a2a-inventory-<timestamp>`). The script is **read-only** against Azure and:

- **Does not upload anything** — no results are sent to GitHub, to the script's author,
  or to any third party. There is no telemetry and nothing "phones home."
- **Cannot write back to this repository** — cloning or downloading only *pulls* the
  script to you. Pushing to this public repo would require the owner's credentials,
  which you don't have.
- **Ignores its own output in git** — the included `.gitignore` excludes
  `azure-a2a-inventory-*` folders, so even if you run the script inside your local clone,
  the output is never tracked or committed by accident.

### What the output contains — treat it as confidential

The output holds **no passwords or secrets**, but it does contain **sensitive metadata**:
resource names, IP addresses, principal/object IDs, and RBAC role assignments. Handle it
like any internal document:

- **Do not** commit real output to a public repository.
- **Do not** paste it into public locations or share it over insecure channels.
- Store and share it only through your organization's approved, access-controlled means.

The `sample-output/` folder is **fabricated** demo data and is safe to share.

---

## License

[MIT](LICENSE)

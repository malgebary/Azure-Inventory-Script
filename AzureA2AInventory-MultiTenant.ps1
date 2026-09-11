<#
.SYNOPSIS
Option B: run the Azure inventory across MULTIPLE tenants in one go.

.DESCRIPTION
A thin wrapper around AzureA2AInventory.ps1. It signs in and runs the full
inventory once PER tenant, writing a separate timestamped output folder for each,
then drops a small index file listing every run.

Use this when your estate spans several Entra tenants (for example CSP-billed
subscriptions in one tenant and your own subscriptions in another). For a single
tenant, just run AzureA2AInventory.ps1 directly (Option A).

All the same optional switches are supported and passed straight through to each
per-tenant run.

.PARAMETER TenantIds
One or more tenant GUIDs to process, in order.

.PARAMETER OutputRoot
Parent folder to hold the per-tenant output folders. Defaults to
.\azure-a2a-inventory-multi-<timestamp>.

.PARAMETER UseDeviceAuthentication
Device-code sign-in (URL + code) instead of the browser popup. Recommended for
multi-tenant runs so each tenant sign-in is explicit.

.PARAMETER IncludeRoleAssignments
.PARAMETER IncludePolicyAssignments
.PARAMETER IncludeVmInsightsConnections
.PARAMETER IncludeAppInsightsDependencies
.PARAMETER IncludeStorageLinks
.PARAMETER IncludeDependencies
.PARAMETER LookbackDays
    Passed through unchanged to AzureA2AInventory.ps1 for every tenant.

.EXAMPLE
.\AzureA2AInventory-MultiTenant.ps1 -TenantIds "<tenant-1>","<tenant-2>","<tenant-3>" -UseDeviceAuthentication

.EXAMPLE
.\AzureA2AInventory-MultiTenant.ps1 -TenantIds "<t1>","<t2>" -UseDeviceAuthentication -IncludeRoleAssignments -IncludeDependencies
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$TenantIds,

    [string]$OutputRoot = ".\azure-a2a-inventory-multi-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [switch]$UseDeviceAuthentication,
    [switch]$IncludeRoleAssignments,
    [switch]$IncludePolicyAssignments,
    [switch]$IncludeVmInsightsConnections,
    [switch]$IncludeAppInsightsDependencies,
    [switch]$IncludeStorageLinks,
    [switch]$IncludeDependencies,
    [int]$LookbackDays = 30
)

$ErrorActionPreference = "Stop"

$mainScript = Join-Path $PSScriptRoot "AzureA2AInventory.ps1"
if (-not (Test-Path $mainScript)) {
    throw "Could not find AzureA2AInventory.ps1 next to this wrapper (looked in '$PSScriptRoot')."
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRootResolved = (Resolve-Path $OutputRoot).Path

Write-Host ""
Write-Host "Multi-tenant inventory run"
Write-Host "Tenants: $($TenantIds.Count)"
Write-Host "Output root: $OutputRootResolved"
Write-Host ""

$index = New-Object System.Collections.Generic.List[object]

foreach ($tid in $TenantIds) {
    Write-Host "==================================================================="
    Write-Host " Tenant: $tid"
    Write-Host "==================================================================="

    $tenantOut = Join-Path $OutputRootResolved $tid

    # Build the argument set passed through to the per-tenant run.
    $params = @{
        TenantId   = $tid
        OutputPath = $tenantOut
        LookbackDays = $LookbackDays
    }
    if ($UseDeviceAuthentication)        { $params.UseDeviceAuthentication = $true }
    if ($IncludeRoleAssignments)         { $params.IncludeRoleAssignments = $true }
    if ($IncludePolicyAssignments)       { $params.IncludePolicyAssignments = $true }
    if ($IncludeVmInsightsConnections)   { $params.IncludeVmInsightsConnections = $true }
    if ($IncludeAppInsightsDependencies) { $params.IncludeAppInsightsDependencies = $true }
    if ($IncludeStorageLinks)            { $params.IncludeStorageLinks = $true }
    if ($IncludeDependencies)            { $params.IncludeDependencies = $true }

    $status = "succeeded"
    $errorMessage = ""
    try {
        & $mainScript @params
    }
    catch {
        $status = "failed"
        $errorMessage = $_.Exception.Message
        Write-Warning "Tenant '$tid' failed: $errorMessage"
    }

    $index.Add([pscustomobject]@{
        tenantId     = $tid
        status       = $status
        outputFolder = $tenantOut
        error        = $errorMessage
    })

    Write-Host ""
}

# Write an index of all per-tenant runs.
$index | Export-Csv -Path (Join-Path $OutputRootResolved "tenants-index.csv") -NoTypeInformation -Encoding UTF8
$index | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputRootResolved "tenants-index.json") -Encoding UTF8

$succeeded = ($index | Where-Object status -eq "succeeded").Count
$failed    = ($index | Where-Object status -eq "failed").Count

Write-Host "==================================================================="
Write-Host "Multi-tenant run complete."
Write-Host "  Succeeded: $succeeded"
Write-Host "  Failed:    $failed"
Write-Host "Output root: $OutputRootResolved"
if ($failed -gt 0) {
    Write-Host "See tenants-index.csv for per-tenant status and errors."
}

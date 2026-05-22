#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster analytics-starrocks env -- Phase 0.G.6.

.DESCRIPTION
  Drives terraform/envs/analytics-starrocks/ (6 StarRocks nodes: 3 FE + 3 BE) on
  the per-cluster state + per-engine template canon. Builds AFTER 0.G.5
  (ClickHouse) is sealed + its VMs stopped (feedback_minimal_running_vms.md).

  Pre-flight (see docs/handbook.md §1.B):
    1. nexus-infra-vmware foundation env applied (dhcp-host reservations for the
       6 StarRocks MACs :93-:98 at .31-.36 + round-robin starrocks-fe.nexus.lab +
       the analytics NFS export extended to the 3 BE).
    2. nexus-infra-vmware security env applied (starrocks-server PKI role + 6
       AppRole sidecars + KV seeds at nexus/analytics/starrocks/*).
    3. packer build packer/analytics-starrocks-fe-node + packer/analytics-starrocks-be-node.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate

.PARAMETER Vars
  "key=value" pairs forwarded as -var flags (full override set per apply).

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.G.6.ps1.

.EXAMPLE
  pwsh -File scripts\analytics-starrocks.ps1 cycle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\analytics-starrocks'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.G.6.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[analytics-starrocks] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
        Push-Location $envDir
        try {
            & terraform init
            if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Initialize-TerraformIfNeeded
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve  (envs/analytics-starrocks)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/analytics-starrocks)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.G.6.ps1  (StarRocks cluster gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/analytics-starrocks)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/analytics-starrocks)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/analytics-starrocks)'
    Invoke-Terraform @('validate')
}

switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "analytics-starrocks $Verb complete" -ForegroundColor Green

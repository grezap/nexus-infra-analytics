#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster analytics-starrocks-sd env -- Phase 0.L.5 (ADR-0037).

.DESCRIPTION
  Drives terraform/envs/analytics-starrocks-sd/ (5 StarRocks shared-data nodes:
  3 FE + 2 CN, run_mode=shared_data, internal tables in a MinIO storage volume)
  on the per-cluster state + per-engine template canon. SEPARATE cluster from
  the sealed shared-nothing 0.G.6 cluster.

  Pre-flight (see docs/handbook.md §1.C):
    1. nexus-infra-vmware foundation env applied (dhcp + DNS extended with the
       5 sd nodes + starrocks-sd-fe.nexus.lab round-robin).
    2. nexus-infra-vmware security env applied (starrocks-sd-server PKI role + 5
       AppRole sidecars + KV seeds at nexus/analytics/starrocks-sd/*; minio agent
       policy v2 -- so minio-1 can read the SR S3 creds during the tenant bootstrap).
    3. nexus-infra-lakehouse lakehouse-minio apply done (MinIO 4 VMs up + the
       starrocks bucket + nexus-starrocks-app identity + scoped policy live).
    4. packer build packer/analytics-starrocks-sd-fe-node + packer/analytics-
       starrocks-sd-cn-node.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate

.PARAMETER Vars
  "key=value" pairs forwarded as -var flags (full override set per apply).

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.L.5.ps1.

.EXAMPLE
  pwsh -File scripts\analytics-starrocks-sd.ps1 cycle
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
$envDir    = Join-Path $repoRoot 'terraform\envs\analytics-starrocks-sd'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.L.5.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[analytics-starrocks-sd] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/analytics-starrocks-sd)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/analytics-starrocks-sd)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.L.5.ps1  (StarRocks shared-data cluster gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/analytics-starrocks-sd)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/analytics-starrocks-sd)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/analytics-starrocks-sd)'
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
Write-Host "analytics-starrocks-sd $Verb complete" -ForegroundColor Green

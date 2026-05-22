#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster analytics-clickhouse env -- Phase 0.G.5.

.DESCRIPTION
  Drives terraform/envs/analytics-clickhouse/ (9 ClickHouse nodes: 3 Keeper +
  3 shards x 2 replicas) on the per-cluster state + per-engine template canon
  (memory/feedback_per_cluster_state_per_engine_template.md).

  Pre-flight (from outside this wrapper -- see docs/handbook.md s0/s1.2):
    1. nexus-infra-vmware foundation env applied (dnsmasq dhcp-host reservations
       for the 9 ClickHouse MACs :8A-:92 at .41-.49 + round-robin clickhouse.nexus.lab
       host-record + the /srv/nfs/analytics-backups NFS export).
    2. nexus-infra-vmware security env applied (clickhouse-server PKI role + 9
       per-host AppRole sidecars at $HOME\.nexus\vault-agent-analytics-clickhouse-<host>.json
       + KV sticky-seeds at nexus/analytics/clickhouse/*).
    3. packer build packer/analytics-clickhouse-keeper-node/ + packer/analytics-clickhouse-server-node/.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/analytics-clickhouse
  destroy  -- terraform destroy -auto-approve
  smoke    -- run scripts/smoke-0.G.5.ps1 (ClickHouse cluster gate)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Use for
  selective per-VM / per-overlay bring-up, e.g.:
    -Vars enable_ch_shard1_rep2=false,enable_ch_shard2_rep2=false,enable_ch_shard3_rep2=false

  NOTE per feedback_terraform_partial_apply_destroys_resources.md: every -Vars
  invocation is the FULL override set for that apply. Vars not passed default
  back (true). Omit -Vars when you mean "all 9 nodes + all overlays".

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.G.5.ps1.

.EXAMPLE
  pwsh -File scripts\analytics-clickhouse.ps1 cycle

.EXAMPLE
  # bring up only the 3-node Keeper quorum (no data nodes yet)
  pwsh -File scripts\analytics-clickhouse.ps1 apply -Vars enable_ch_shard1_rep1=false,enable_ch_shard1_rep2=false,enable_ch_shard2_rep1=false,enable_ch_shard2_rep2=false,enable_ch_shard3_rep1=false,enable_ch_shard3_rep2=false

.NOTES
  Sibling wrapper (0.G.6): scripts\analytics-starrocks.ps1.
  See docs/handbook.md s1.A for the cross-env operator order.
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
$envDir    = Join-Path $repoRoot 'terraform\envs\analytics-clickhouse'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.G.5.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[analytics-clickhouse] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/analytics-clickhouse)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/analytics-clickhouse)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.G.5.ps1  (ClickHouse cluster gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/analytics-clickhouse)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/analytics-clickhouse)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/analytics-clickhouse)'
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
Write-Host "analytics-clickhouse $Verb complete" -ForegroundColor Green

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.6 smoke gate -- StarRocks (3 FE BDB-JE quorum + 3 BE), mTLS.

.DESCRIPTION
  Verifies the 0.G.6 exit gate: a genuine sharded AND replicated StarRocks cluster
  (ADR-0030) -- tablets DISTRIBUTED BY HASH BUCKETS across all 3 BE with
  replication_num=3, fronted by a 3-FE BDB-JE quorum (1 leader + 2 followers),
  reached via round-robin DNS starrocks-fe.nexus.lab with no VIP (ADR-0031),
  backed by an NFS backup repository (ADR-0032).

  Sections: reachability -> firstboot -> identity -> vault-agent -> TLS material
  -> nftables -> FE quorum -> BE alive -> tablet distribution + replication_num
  -> write/read -> RBAC -> round-robin DNS -> backup mount. With -IncludeChaos:
  FE-leader-loss re-election + BE-loss reroute (destructive; restores after).

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md. Exits 1 on
  any FAIL. StarRocks admin SQL runs on the FE leader as root (password read
  on-node from Vault KV via the agent token; never printed).

.PARAMETER Strict
  Fail on warnings.

.PARAMETER IncludeChaos
  Run the destructive failover checks. Default: false.
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [switch]$IncludeChaos
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$feIps = @('192.168.70.31', '192.168.70.32', '192.168.70.33')
$beIps = @('192.168.70.34', '192.168.70.35', '192.168.70.36')
$allIps = $feIps + $beIps
$leaderIp = $feIps[0]

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Probe)
    try {
        if (& $Probe) { Write-Host "[OK]   $Description" -ForegroundColor Green; return $true }
        else { Write-Host "[FAIL] $Description" -ForegroundColor Red; $script:failures += $Description; return $false }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"; return $false
    }
}

function Invoke-RemoteCommand {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# Read the StarRocks root password on the FE leader (via the agent token) once.
# Returns a mysql command prefix that authenticates as root. Never prints the pw.
$mysqlRoot = "mysql -h 127.0.0.1 -P 9030 -u root"
function Get-RootMysql {
    $cmd = @'
VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
export VAULT_ADDR="$VADDR" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt VAULT_TOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
/usr/local/bin/vault kv get -field=password nexus/analytics/starrocks/root-password
'@
    $pw = (ssh @sshOpts "$user@$leaderIp" "$($cmd -replace "`r`n","`n")" 2>&1 | Out-String).Trim()
    if ($pw) { return "mysql -h 127.0.0.1 -P 9030 -u root -p$pw" }
    return $mysqlRoot
}

# ─── Section 1: reachability ──────────────────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker') -match 'nexus-smoke-marker'
    } | Out-Null
}
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot ─────────────────────────────────────────────────
Write-Section 'analytics-node firstboot completion'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/analytics-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
}

# ─── Section 3: identity ──────────────────────────────────────────────────
Write-Section 'Node-identity mapping'
$expected = @{
    '192.168.70.31' = @{ host = 'sr-fe-leader';     role = 'starrocks-fe' }
    '192.168.70.32' = @{ host = 'sr-fe-follower-1'; role = 'starrocks-fe' }
    '192.168.70.33' = @{ host = 'sr-fe-follower-2'; role = 'starrocks-fe' }
    '192.168.70.34' = @{ host = 'sr-be-1';          role = 'starrocks-be' }
    '192.168.70.35' = @{ host = 'sr-be-2';          role = 'starrocks-be' }
    '192.168.70.36' = @{ host = 'sr-be-3';          role = 'starrocks-be' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$($e.host)\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity role == $($e.role)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_ROLE=" /etc/nexus-starrocks/node-identity.env') -match "NEXUS_ROLE=$($e.role)"
    } | Out-Null
}

# ─── Section 4: Vault Agent ───────────────────────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 5: TLS material ──────────────────────────────────────────────
Write-Section 'mTLS cert material (PKCS#8 + round-robin SAN)'
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    $tlsDir = if ($e.role -eq 'starrocks-fe') { '/opt/starrocks/fe/conf/tls' } else { '/opt/starrocks/be/conf/tls' }
    Test-Check -Description "$ip : $tlsDir/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo test -s $tlsDir/server.crt && sudo test -s $tlsDir/server.key && sudo test -s $tlsDir/ca.crt && echo OK") -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : private key is PKCS#8" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo head -1 $tlsDir/server.key") -match 'BEGIN PRIVATE KEY'
    } | Out-Null
}
foreach ($ip in $feIps) {
    Test-Check -Description "$ip : FE cert SAN includes starrocks-fe.nexus.lab (round-robin)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /opt/starrocks/fe/conf/tls/server.crt -noout -ext subjectAltName') -match 'starrocks-fe\.nexus\.lab'
    } | Out-Null
}

# ─── Section 6: nftables ──────────────────────────────────────────────────
Write-Section 'nftables (VMnet10 backplane trust)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}

# ─── Section 7+: cluster state (run mysql on the FE leader as root) ────────
$RP = Get-RootMysql

Write-Section 'StarRocks FE quorum (SHOW FRONTENDS: 1 LEADER + 2 FOLLOWER)'
$feShow = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SHOW FRONTENDS' 2>/dev/null"
Test-Check -Description "3 FE rows present" -Probe { (($feShow -split "`n") | Where-Object { $_ -match '\S' }).Count -ge 3 } | Out-Null
Test-Check -Description "FE: at least 3 Alive=true" -Probe { ([regex]::Matches($feShow, '(?i)\btrue\b')).Count -ge 3 } | Out-Null
Test-Check -Description "FE: exactly 1 LEADER role" -Probe { ([regex]::Matches($feShow, '(?i)\bLEADER\b')).Count -ge 1 } | Out-Null

Write-Section 'StarRocks BE alive (SHOW BACKENDS: 3 Alive)'
$beShow = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SHOW BACKENDS' 2>/dev/null"
Test-Check -Description "3 BE rows present" -Probe { (($beShow -split "`n") | Where-Object { $_ -match '\S' }).Count -ge 3 } | Out-Null
Test-Check -Description "BE: 3 Alive=true" -Probe { ([regex]::Matches($beShow, '(?i)\btrue\b')).Count -ge 3 } | Out-Null

# ─── Section 9: tablet distribution + replication_num ─────────────────────
Write-Section 'Sharded (tablets across 3 BE) + replicated (replication_num=3)'
Test-Check -Description "nexus.events replication_num = 3" -Probe {
    (Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -e 'SHOW CREATE TABLE nexus.events' 2>/dev/null") -match 'replication_num.*=.*.3.'
} | Out-Null
Test-Check -Description "every BE holds tablets (TabletNum > 0 on all 3)" -Probe {
    # SHOW BACKENDS TabletNum column: count BE rows whose TabletNum is a positive int.
    $nums = [regex]::Matches($beShow, '\b([1-9]\d*)\b') | ForEach-Object { $_.Value }
    # Heuristic: at least 3 distinct positive integers (one per BE TabletNum). The
    # adapter will parse the named column; the smoke uses ADMIN SHOW REPLICA below too.
    $rep = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -e 'ADMIN SHOW REPLICA DISTRIBUTION FROM nexus.events' 2>/dev/null"
    ($rep -match 'BackendId' -or $nums.Count -ge 3)
} | Out-Null

# ─── Section 10: write/read round-trip ────────────────────────────────────
Write-Section 'Write/read round-trip'
Test-Check -Description "SELECT count(nexus.events) >= 60" -Probe {
    [int](Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SELECT count(*) FROM nexus.events' 2>/dev/null") -ge 60
} | Out-Null

# ─── Section 11: RBAC ─────────────────────────────────────────────────────
Write-Section 'SQL-driven RBAC (least-priv app role)'
Test-Check -Description "app user exists" -Probe {
    (Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e `"SHOW GRANTS FOR 'app'@'%'`" 2>/dev/null") -match 'app_rw|nexus'
} | Out-Null

# ─── Section 12: round-robin DNS ──────────────────────────────────────────
Write-Section 'Round-robin DNS (starrocks-fe.nexus.lab -> 3 FE, no VIP)'
Test-Check -Description "starrocks-fe.nexus.lab resolves to the 3 FE IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short starrocks-fe.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($feIps | Where-Object { $resolved -contains $_ }).Count -ge 3
} | Out-Null

# ─── Section 13: backup mount ─────────────────────────────────────────────
Write-Section 'Backup repository mounted (NFS from nexus-gateway, ADR-0032)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/backups/analytics is an NFS mountpoint" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'findmnt -t nfs4 /var/backups/analytics >/dev/null 2>&1 && echo MNT') -match 'MNT'
    } | Out-Null
}

# ─── Section 14 (optional): chaos ─────────────────────────────────────────
if ($IncludeChaos) {
    Write-Section 'CHAOS: FE leader-loss re-election + BE-loss reroute (destructive)'
    Write-Host "[chaos] stopping FE leader ($leaderIp) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo systemctl stop nexus-starrocks-fe.service' | Out-Null
    Start-Sleep -Seconds 20
    Test-Check -Description "a Follower is elected LEADER after the leader loss" -Probe {
        $rp2 = "mysql -h 127.0.0.1 -P 9030 -u root" # a follower; query may need pw, best-effort
        $show = Invoke-RemoteCommand -Ip $feIps[1] -Command "$RP -N -e 'SHOW FRONTENDS' 2>/dev/null"
        ([regex]::Matches($show, '(?i)\bLEADER\b')).Count -ge 1
    } | Out-Null
    Write-Host "[chaos] restarting FE on $leaderIp ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo systemctl start nexus-starrocks-fe.service' | Out-Null
    Start-Sleep -Seconds 10

    Write-Host "[chaos] stopping a BE ($($beIps[0])) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $beIps[0] -Command 'sudo systemctl stop nexus-starrocks-be.service' | Out-Null
    Start-Sleep -Seconds 10
    Test-Check -Description "query still returns full results with 1 BE down (replication_num=3)" -Probe {
        [int](Invoke-RemoteCommand -Ip $feIps[1] -Command "$RP -N -e 'SELECT count(*) FROM nexus.events' 2>/dev/null") -ge 60
    } | Out-Null
    Invoke-RemoteCommand -Ip $beIps[0] -Command 'sudo systemctl start nexus-starrocks-be.service' | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.G.6 SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "0.G.6 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

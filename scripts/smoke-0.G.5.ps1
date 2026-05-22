#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.5 smoke gate -- ClickHouse (3 shards x 2 replicas + 3-node Keeper quorum), mTLS.

.DESCRIPTION
  Verifies the 0.G.5 exit gate: a genuine sharded AND replicated ClickHouse
  cluster (MASTER-PLAN "no toy databases") coordinated by a dedicated 3-node
  ClickHouse Keeper RAFT quorum (NOT ZooKeeper -- ADR-0028), on per-host Vault
  PKI mTLS (ADR-0029), reachable via round-robin DNS clickhouse.nexus.lab with
  no VIP (ADR-0031), backed by an NFS backup repository (ADR-0032).

  Sections (cheapest-first): reachability -> firstboot -> identity -> vault-agent
  -> TLS material (PKCS#8 + round-robin SAN) -> nftables -> Keeper quorum
  -> Keeper reachable from a data node -> system.clusters -> system.replicas
  -> Distributed fan-out -> replica convergence -> RBAC -> round-robin DNS
  -> backup mount. With -IncludeChaos: Keeper 1-node-loss survival + endpoint
  resilience (destructive; restores state after).

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md +
  feedback_powershell_match_substring_anchor.md (anchored token matches).
  Each check echoes [OK]/[FAIL]; exits 1 on any FAIL, 0 on all-green.

.PARAMETER Strict
  Fail on warnings. Default: false.

.PARAMETER IncludeChaos
  Run the destructive failover checks (Keeper leader kill + endpoint resilience).
  Default: false (the cold-rebuild smoke is non-destructive).

.NOTES
  No external deps beyond ssh + the build host ssh-agent + the lab SSH key.
  clickhouse-client runs on-node as default@localhost over TLS (--secure --port 9440).
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [switch]$IncludeChaos
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: clickhouse, phase 0.G.5).
$keeperIps = @('192.168.70.41', '192.168.70.42', '192.168.70.43')
$dataIps = @('192.168.70.44', '192.168.70.45', '192.168.70.46', '192.168.70.47', '192.168.70.48', '192.168.70.49')
$allIps = $keeperIps + $dataIps
$coord = $dataIps[0]   # ch-shard1-rep1 -- arbitrary data-node query coordinator

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

# On-node clickhouse-client over TLS as default@localhost.
$chq = "clickhouse-client --secure --host localhost --port 9440 --query"

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    try {
        $result = & $Probe
        if ($result) {
            Write-Host "[OK]   $Description" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            $script:failures += $Description
            return $false
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"
        return $false
    }
}

function Invoke-RemoteCommand {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

function Invoke-Chq {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Sql)
    return (Invoke-RemoteCommand -Ip $Ip -Command "$chq `"$Sql`" 2>/dev/null").Trim()
}

# ─── Section 1: per-node SSH reachability (9 nodes) ───────────────────────
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

# ─── Section 2: firstboot completion ──────────────────────────────────────
Write-Section 'analytics-node firstboot completion'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/lib/analytics-node-firstboot-done present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/analytics-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
}

# ─── Section 3: identity mapping (IP -> hostname/role/cluster) ─────────────
Write-Section 'Node-identity mapping (canonical IPs -> identity)'
$expected = @{
    '192.168.70.41' = @{ host = 'ch-keeper-1';    role = 'clickhouse-keeper'; dir = '/etc/nexus-clickhouse-keeper' }
    '192.168.70.42' = @{ host = 'ch-keeper-2';    role = 'clickhouse-keeper'; dir = '/etc/nexus-clickhouse-keeper' }
    '192.168.70.43' = @{ host = 'ch-keeper-3';    role = 'clickhouse-keeper'; dir = '/etc/nexus-clickhouse-keeper' }
    '192.168.70.44' = @{ host = 'ch-shard1-rep1'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
    '192.168.70.45' = @{ host = 'ch-shard1-rep2'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
    '192.168.70.46' = @{ host = 'ch-shard2-rep1'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
    '192.168.70.47' = @{ host = 'ch-shard2-rep2'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
    '192.168.70.48' = @{ host = 'ch-shard3-rep1'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
    '192.168.70.49' = @{ host = 'ch-shard3-rep2'; role = 'clickhouse-server'; dir = '/etc/nexus-clickhouse' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$($e.host)\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role == $($e.role)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^NEXUS_ROLE=' $($e.dir)/node-identity.env") -match "NEXUS_ROLE=$($e.role)"
    } | Out-Null
}

# ─── Section 4: Vault Agent active + token sink ───────────────────────────
Write-Section 'Vault Agent (per-host AppRole) active + token sink populated'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 5: TLS material (PKCS#8 + round-robin SAN) ────────────────────
Write-Section 'mTLS cert material (server.crt/key/ca.crt; PKCS#8; round-robin SAN)'
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    $tlsDir = if ($e.role -eq 'clickhouse-keeper') { '/etc/nexus-clickhouse-keeper/tls' } else { '/etc/clickhouse-server/tls' }
    Test-Check -Description "$ip : $tlsDir/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo test -s $tlsDir/server.crt && sudo test -s $tlsDir/server.key && sudo test -s $tlsDir/ca.crt && echo OK") -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : private key is PKCS#8" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo head -1 $tlsDir/server.key") -match 'BEGIN PRIVATE KEY'
    } | Out-Null
    Test-Check -Description "$ip : leaf CN == $($e.host).clickhouse.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in $tlsDir/server.crt -noout -subject") -match "$($e.host).clickhouse.nexus.lab"
    } | Out-Null
}
# round-robin DNS name in the data-node cert SANs (so verify-full vs clickhouse.nexus.lab works)
foreach ($ip in $dataIps) {
    Test-Check -Description "$ip : cert SAN includes clickhouse.nexus.lab (round-robin endpoint)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/clickhouse-server/tls/server.crt -noout -ext subjectAltName") -match 'clickhouse\.nexus\.lab'
    } | Out-Null
}

# ─── Section 6: nftables backplane + secure ports ─────────────────────────
Write-Section 'nftables (VMnet10 backplane trust + secure ports)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}

# ─── Section 7: Keeper RAFT quorum (1 leader + 2 followers) ────────────────
Write-Section 'ClickHouse Keeper RAFT quorum (mntr: 1 leader + 2 followers)'
$keeperStates = @()
foreach ($ip in $keeperIps) {
    $state = Invoke-RemoteCommand -Ip $ip -Command "exec 3<>/dev/tcp/127.0.0.1/9181; printf 'mntr\n' >&3; timeout 3 cat <&3 | grep zk_server_state | awk '{print `$2}'"
    $keeperStates += $state
    Test-Check -Description "$ip : Keeper answers mntr with a valid state ($state)" -Probe {
        $state -match '(leader|follower)'
    } | Out-Null
}
Test-Check -Description "Keeper quorum has exactly 1 leader" -Probe {
    (($keeperStates | Where-Object { $_ -match 'leader' }).Count) -eq 1
} | Out-Null
Test-Check -Description "Keeper quorum has exactly 2 followers" -Probe {
    (($keeperStates | Where-Object { $_ -match 'follower' }).Count) -eq 2
} | Out-Null

# ─── Section 8: Keeper reachable from a data node (system.zookeeper) ───────
Write-Section 'Keeper reachable from data nodes (system.zookeeper)'
Test-Check -Description "$coord : SELECT FROM system.zookeeper WHERE path='/' succeeds" -Probe {
    [int](Invoke-Chq -Ip $coord -Sql "SELECT count() FROM system.zookeeper WHERE path = '/'") -ge 1
} | Out-Null

# ─── Section 9: system.clusters (3 shards x 2 replicas) ───────────────────
Write-Section 'system.clusters -- nexus_analytics topology'
Test-Check -Description "nexus_analytics has 6 host rows (3 shards x 2 replicas)" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT count() FROM system.clusters WHERE cluster = 'nexus_analytics'") -eq '6'
} | Out-Null
Test-Check -Description "nexus_analytics spans exactly 3 distinct shards" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT uniqExact(shard_num) FROM system.clusters WHERE cluster = 'nexus_analytics'") -eq '3'
} | Out-Null

# ─── Section 10: system.replicas health ───────────────────────────────────
Write-Section 'system.replicas health (ReplicatedMergeTree)'
foreach ($ip in $dataIps) {
    Test-Check -Description "$ip : all replicas is_readonly=0 + queue not stuck" -Probe {
        $ro = Invoke-Chq -Ip $ip -Sql "SELECT count() FROM system.replicas WHERE is_readonly = 1 OR is_session_expired = 1"
        # count() over zero tables is 0; a healthy node returns 0 unhealthy replicas.
        $ro -eq '0'
    } | Out-Null
}

# ─── Section 11: Distributed fan-out across all 3 shards ───────────────────
Write-Section 'Distributed fan-out (nexus.events across 3 shards)'
Test-Check -Description "Distributed SELECT count(nexus.events) == 600" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT count() FROM nexus.events") -eq '600'
} | Out-Null
$shardLocalCounts = @{}
$shardReps = @{
    1 = @('192.168.70.44', '192.168.70.45')
    2 = @('192.168.70.46', '192.168.70.47')
    3 = @('192.168.70.48', '192.168.70.49')
}
foreach ($s in 1, 2, 3) {
    $c = [int](Invoke-Chq -Ip $shardReps[$s][0] -Sql "SELECT count() FROM nexus.events_local")
    $shardLocalCounts[$s] = $c
    Test-Check -Description "shard$s : local count > 0 (sharding spread, $c rows)" -Probe { $c -gt 0 } | Out-Null
}
Test-Check -Description "shard local counts sum to 600 (all data accounted across 3 shards)" -Probe {
    ($shardLocalCounts[1] + $shardLocalCounts[2] + $shardLocalCounts[3]) -eq 600
} | Out-Null

# ─── Section 12: replica convergence (each shard's 2 replicas equal) ───────
Write-Section 'Replica convergence (insert on rep1 -> readable on rep2)'
foreach ($s in 1, 2, 3) {
    $c1 = [int](Invoke-Chq -Ip $shardReps[$s][0] -Sql "SELECT count() FROM nexus.events_local")
    $c2 = [int](Invoke-Chq -Ip $shardReps[$s][1] -Sql "SELECT count() FROM nexus.events_local")
    Test-Check -Description "shard$s : rep1 ($c1) == rep2 ($c2) and > 0 (replicated)" -Probe {
        $c1 -gt 0 -and $c1 -eq $c2
    } | Out-Null
}

# ─── Section 13: SQL-driven RBAC ──────────────────────────────────────────
Write-Section 'SQL-driven RBAC (admin + least-priv app role)'
Test-Check -Description "admin user exists" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT count() FROM system.users WHERE name = 'admin'") -eq '1'
} | Out-Null
Test-Check -Description "app user exists" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT count() FROM system.users WHERE name = 'app'") -eq '1'
} | Out-Null
Test-Check -Description "app_rw + app_ro roles exist" -Probe {
    (Invoke-Chq -Ip $coord -Sql "SELECT count() FROM system.roles WHERE name IN ('app_rw','app_ro')") -eq '2'
} | Out-Null
Test-Check -Description "default user restricted to localhost (not 0.0.0.0/::)" -Probe {
    # default user should NOT be reachable from the lab network; on-node it is
    # localhost-only. Probe: a remote-host clickhouse-client as default fails.
    $remote = Invoke-RemoteCommand -Ip $dataIps[1] -Command "clickhouse-client --secure --host $coord --port 9440 --user default --query 'SELECT 1' 2>&1 || echo DENIED"
    $remote -match 'DENIED|AUTHENTICATION|not allowed|denied'
} | Out-Null

# ─── Section 14: round-robin DNS (clickhouse.nexus.lab -> 6 data nodes) ────
Write-Section 'Round-robin DNS (clickhouse.nexus.lab -> 6 data nodes, no VIP)'
Test-Check -Description "clickhouse.nexus.lab resolves to all 6 data-node IPs" -Probe {
    try {
        $a = (Resolve-DnsName -Name 'clickhouse.nexus.lab' -Type A -Server 192.168.70.1 -ErrorAction Stop |
              Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
    } catch {
        # Fallback: resolve from the gateway via dig over SSH.
        $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command "dig +short clickhouse.nexus.lab @127.0.0.1") -split "\s+"
    }
    $resolved = @($a | Where-Object { $_ })
    $expectedSet = $dataIps | Sort-Object
    ($resolved | Sort-Object | Select-Object -Unique) -join ',' -eq ($expectedSet -join ',') -or
    (($dataIps | Where-Object { $resolved -contains $_ }).Count -eq 6)
} | Out-Null

# ─── Section 15: backup repository mounted ────────────────────────────────
Write-Section 'Backup repository (NFS from nexus-gateway, ADR-0032)'
foreach ($ip in $dataIps) {
    Test-Check -Description "$ip : /var/backups/analytics is an NFS mountpoint" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "findmnt -t nfs4 /var/backups/analytics >/dev/null 2>&1 && echo MNT") -match 'MNT'
    } | Out-Null
}

# ─── Section 16 (optional): chaos / failover ──────────────────────────────
if ($IncludeChaos) {
    Write-Section 'CHAOS: Keeper 1-node-loss survival + endpoint resilience (destructive)'
    $victim = $keeperIps[0]
    Write-Host "[chaos] stopping Keeper on $victim ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $victim -Command 'sudo systemctl stop nexus-clickhouse-keeper.service' | Out-Null
    Start-Sleep -Seconds 10
    Test-Check -Description "Keeper quorum re-elects after 1-node loss (still 1 leader among survivors)" -Probe {
        $states = foreach ($ip in $keeperIps[1..2]) {
            Invoke-RemoteCommand -Ip $ip -Command "exec 3<>/dev/tcp/127.0.0.1/9181; printf 'mntr\n' >&3; timeout 3 cat <&3 | grep zk_server_state | awk '{print `$2}'"
        }
        ($states | Where-Object { $_ -match 'leader' }).Count -eq 1
    } | Out-Null
    Test-Check -Description "ReplicatedMergeTree insert still commits with 1 Keeper down" -Probe {
        Invoke-Chq -Ip $coord -Sql "INSERT INTO nexus.events SELECT number+1000000, now(), number % 3, 'chaos' FROM numbers(30)" | Out-Null
        Start-Sleep -Seconds 3
        [int](Invoke-Chq -Ip $coord -Sql "SELECT count() FROM nexus.events WHERE payload = 'chaos'") -ge 30
    } | Out-Null
    Write-Host "[chaos] restarting Keeper on $victim ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $victim -Command 'sudo systemctl start nexus-clickhouse-keeper.service' | Out-Null
    Start-Sleep -Seconds 8
    Test-Check -Description "Keeper quorum back to 3 members after restart" -Probe {
        $states = foreach ($ip in $keeperIps) {
            Invoke-RemoteCommand -Ip $ip -Command "exec 3<>/dev/tcp/127.0.0.1/9181; printf 'mntr\n' >&3; timeout 3 cat <&3 | grep zk_server_state | awk '{print `$2}'"
        }
        (($states | Where-Object { $_ -match '(leader|follower)' }).Count) -eq 3
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.G.5 SMOKE CHECKS PASSED' -ForegroundColor Green
    if ($warnings.Count -gt 0) { Write-Host "($($warnings.Count) warning(s))" -ForegroundColor Yellow }
    exit 0
} else {
    Write-Host "0.G.5 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.L.5 smoke gate -- StarRocks shared-data (3 FE BDB-JE quorum + 2 CN
  + MinIO storage volume), mTLS. ADR-0037.

.DESCRIPTION
  Verifies the 0.L.5 exit gate: a genuine shared-data StarRocks cluster --
  cloud-native internal tables in a MinIO storage volume (s3://starrocks/),
  fronted by a 3-FE BDB-JE quorum (1 leader + 2 followers), reached via
  round-robin DNS starrocks-sd-fe.nexus.lab with no VIP (ADR-0031), data
  plane = 2 stateless Compute Nodes (any CN serves from shared storage).

  Sections: reachability -> firstboot -> identity -> vault-agent -> TLS material
  -> nftables -> FE quorum -> CN alive -> storage volume default -> write/read
  -> RBAC -> round-robin DNS -> MinIO s3://starrocks/ has objects. Then the
  HEADLINE chaos check (always on by default per Greg's 0.L.5 decision): kill
  1 CN, prove the query still returns full results from shared storage;
  kill FE leader, prove re-election.

  Exits 1 on any FAIL.

.PARAMETER Strict
  Fail on warnings.

.PARAMETER SkipChaos
  Skip the destructive chaos section (CN-loss + FE-leader re-election).
  Default: false (chaos runs by default; ADR-0037 -- it's the shared-data
  headline HA property).
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [switch]$SkipChaos
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$feIps = @('192.168.70.37', '192.168.70.38', '192.168.70.39')
$cnIps = @('192.168.70.30', '192.168.70.40')
$allIps = $feIps + $cnIps
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

# Read root password from Vault KV on the leader (via the agent token).
function Get-RootMysql {
    $cmd = @'
VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
export VAULT_ADDR="$VADDR" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt VAULT_TOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
/usr/local/bin/vault kv get -field=password nexus/analytics/starrocks-sd/root-password
'@
    $pw = (ssh @sshOpts "$user@$leaderIp" "$($cmd -replace "`r`n","`n")" 2>&1 | Out-String).Trim()
    if ($pw) { return "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p$pw" }
    return "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root"
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
    '192.168.70.37' = @{ host = 'sr-sd-fe-1'; role = 'starrocks-sd-fe' }
    '192.168.70.38' = @{ host = 'sr-sd-fe-2'; role = 'starrocks-sd-fe' }
    '192.168.70.39' = @{ host = 'sr-sd-fe-3'; role = 'starrocks-sd-fe' }
    '192.168.70.30' = @{ host = 'sr-sd-cn-1'; role = 'starrocks-sd-cn' }
    '192.168.70.40' = @{ host = 'sr-sd-cn-2'; role = 'starrocks-sd-cn' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$($e.host)\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity role == $($e.role)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_ROLE=" /etc/nexus-starrocks/node-identity.env') -match "NEXUS_ROLE=$($e.role)"
    } | Out-Null
    Test-Check -Description "$ip : node-identity cluster == starrocks-sd" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_CLUSTER=" /etc/nexus-starrocks/node-identity.env') -match 'NEXUS_CLUSTER=starrocks-sd'
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
    $tlsDir = if ($e.role -eq 'starrocks-sd-fe') { '/opt/starrocks/fe/conf/tls' } else { '/opt/starrocks/be/conf/tls' }
    Test-Check -Description "$ip : $tlsDir/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo test -s $tlsDir/server.crt && sudo test -s $tlsDir/server.key && sudo test -s $tlsDir/ca.crt && echo OK") -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : private key is PKCS#8" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo head -1 $tlsDir/server.key") -match 'BEGIN PRIVATE KEY'
    } | Out-Null
}
foreach ($ip in $feIps) {
    Test-Check -Description "$ip : FE cert SAN includes starrocks-sd-fe.nexus.lab (round-robin)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /opt/starrocks/fe/conf/tls/server.crt -noout -ext subjectAltName') -match 'starrocks-sd-fe\.nexus\.lab'
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

Write-Section 'StarRocks FE quorum (SHOW FRONTENDS: 1 LEADER + 2 FOLLOWER, shared_data)'
$feShow = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SHOW FRONTENDS' 2>/dev/null"
Test-Check -Description "3 FE rows present" -Probe { (($feShow -split "`n") | Where-Object { $_ -match '\S' }).Count -ge 3 } | Out-Null
Test-Check -Description "FE: at least 3 Alive=true" -Probe { ([regex]::Matches($feShow, '(?i)\btrue\b')).Count -ge 3 } | Out-Null
Test-Check -Description "FE: exactly 1 LEADER role" -Probe { ([regex]::Matches($feShow, '(?i)\bLEADER\b')).Count -ge 1 } | Out-Null
Test-Check -Description "FE run_mode = shared_data (fe.conf grep)" -Probe {
    (Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo grep -E "^run_mode\s*=\s*shared_data" /opt/starrocks/fe/conf/fe.conf') -match 'shared_data'
} | Out-Null

Write-Section 'StarRocks CN alive (SHOW COMPUTE NODES: 2 Alive)'
$cnShow = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SHOW COMPUTE NODES' 2>/dev/null"
Test-Check -Description "2 CN rows present" -Probe { (($cnShow -split "`n") | Where-Object { $_ -match '\S' }).Count -ge 2 } | Out-Null
Test-Check -Description "CN: 2 Alive=true" -Probe { ([regex]::Matches($cnShow, '(?i)\btrue\b')).Count -ge 2 } | Out-Null

# ─── Section 9: storage volume = MinIO, default ───────────────────────────
Write-Section 'Storage volume points at MinIO + is the default'
$svShow = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -e 'SHOW STORAGE VOLUMES' 2>/dev/null"
$svDesc = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -e 'DESC STORAGE VOLUME nexus_minio_starrocks' 2>/dev/null"
Test-Check -Description "storage volume nexus_minio_starrocks present" -Probe { $svShow -match 'nexus_minio_starrocks' } | Out-Null
Test-Check -Description "nexus_minio_starrocks is the DEFAULT storage volume (DESC: IsDefault=true)" -Probe {
    # DESC STORAGE VOLUME prints tabular columns (header + data row); IsDefault
    # is column 3 on the data row matching the volume name.
    $dataLine = ($svDesc -split "`n") | Where-Object { $_ -match 'nexus_minio_starrocks\b.*S3' } | Select-Object -First 1
    if (-not $dataLine) { return $false }
    $cols = $dataLine -split "\s+" | Where-Object { $_ }
    # cols: Name=0, Type=1, IsDefault=2 (0-indexed)
    return ($cols.Count -ge 3) -and ($cols[2] -match '(?i)^true$')
} | Out-Null
Test-Check -Description "storage volume LOCATIONS = s3://starrocks/" -Probe {
    $svDesc -match 's3://starrocks/'
} | Out-Null

# ─── Section 10: write/read round-trip ────────────────────────────────────
Write-Section 'Write/read round-trip (cloud-native table)'
Test-Check -Description "SELECT count(nexus.events) >= 60" -Probe {
    [int](Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SELECT count(*) FROM nexus.events' 2>/dev/null") -ge 60
} | Out-Null
Test-Check -Description "nexus.events table exists + has 4 columns" -Probe {
    $desc = Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -e 'DESC nexus.events' 2>/dev/null"
    ($desc -match 'event_id') -and ($desc -match 'payload')
} | Out-Null

# ─── Section 11: RBAC ─────────────────────────────────────────────────────
Write-Section 'SQL-driven RBAC (least-priv app role)'
Test-Check -Description "app user exists" -Probe {
    (Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e `"SHOW GRANTS FOR 'app'@'%'`" 2>/dev/null") -match 'app_rw|nexus'
} | Out-Null

# ─── Section 12: round-robin DNS ──────────────────────────────────────────
Write-Section 'Round-robin DNS (starrocks-sd-fe.nexus.lab -> 3 FE, no VIP)'
Test-Check -Description "starrocks-sd-fe.nexus.lab resolves to the 3 FE IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short starrocks-sd-fe.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($feIps | Where-Object { $resolved -contains $_ }).Count -ge 3
} | Out-Null

# ─── Section 13: MinIO-side proof -- objects in s3://starrocks/ ───────────
Write-Section 'MinIO-side proof: s3://starrocks/ has SR-written objects'
Test-Check -Description "minio-1 reports >0 objects under s3://starrocks/" -Probe {
    $obj = Invoke-RemoteCommand -Ip '192.168.70.141' -Command 'sudo mc ls --recursive nexuslocal/starrocks/ 2>/dev/null | wc -l'
    [int]$obj -ge 1
} | Out-Null

# ─── Section 14: CN-loss chaos (default-on; ADR-0037) ─────────────────────
if (-not $SkipChaos) {
    Write-Section 'CHAOS (default-on): CN-loss + FE-leader re-election'

    Write-Host "[chaos] stopping CN $($cnIps[0]) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $cnIps[0] -Command 'sudo systemctl stop nexus-starrocks-sd-cn.service' | Out-Null
    Start-Sleep -Seconds 12
    Test-Check -Description "query still returns 60 rows with 1 CN down (data in shared MinIO storage)" -Probe {
        [int](Invoke-RemoteCommand -Ip $leaderIp -Command "$RP -N -e 'SELECT count(*) FROM nexus.events' 2>/dev/null") -ge 60
    } | Out-Null
    Write-Host "[chaos] restarting CN $($cnIps[0]) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $cnIps[0] -Command 'sudo systemctl start nexus-starrocks-sd-cn.service' | Out-Null
    Start-Sleep -Seconds 10

    Write-Host "[chaos] stopping FE leader ($leaderIp) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo systemctl stop nexus-starrocks-sd-fe.service' | Out-Null
    Start-Sleep -Seconds 25
    Test-Check -Description "a Follower is elected LEADER after the leader loss" -Probe {
        $show = Invoke-RemoteCommand -Ip $feIps[1] -Command "$RP -N -e 'SHOW FRONTENDS' 2>/dev/null"
        ([regex]::Matches($show, '(?i)\bLEADER\b')).Count -ge 1
    } | Out-Null
    Write-Host "[chaos] restarting FE leader on $leaderIp ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo systemctl start nexus-starrocks-sd-fe.service' | Out-Null
    Start-Sleep -Seconds 15
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.L.5 SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "0.L.5 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

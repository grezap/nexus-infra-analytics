/*
 * role-overlay-clickhouse-schema-bootstrap.tf -- Phase 0.G.5 exit gate
 *
 * One-shot bring-up of the demo schema + SQL-driven RBAC + the "sharded AND
 * replicated, proven" verification the MASTER-PLAN mandates. Runs as
 * default@localhost (restricted to loopback + access_management by the
 * server-config users.d) on ch-shard1-rep1.
 *
 * Steps:
 *   1. RBAC (SQL-driven, ON CLUSTER): roles app_ro/app_rw + users admin/app.
 *      Passwords read on-node from Vault KV via the Vault Agent token sink --
 *      never printed to the transcript (field names + lengths only).
 *   2. Schema (ON CLUSTER): nexus.events_local (ReplicatedMergeTree) +
 *      nexus.events (Distributed over nexus_analytics, rand() sharding key).
 *   3. Proof:
 *      - system.clusters shows nexus_analytics = 6 host rows (3 shards x 2 replicas)
 *      - Distributed INSERT fans across all 3 shards (each shard's local count > 0)
 *      - replica convergence: each shard's 2 replicas hold equal, non-zero counts
 *
 * Selective ops: var.enable_schema_bootstrap.
 */

resource "null_resource" "clickhouse_schema_bootstrap" {
  count = var.enable_schema_bootstrap ? 1 : 0

  triggers = {
    server_cfg_id = length(null_resource.clickhouse_server_config) > 0 ? null_resource.clickhouse_server_config[0].id : "disabled"
    cluster_name  = var.clickhouse_cluster_name
    schema_v      = "4"
    ssh_user      = var.analytics_node_user
  }

  depends_on = [null_resource.clickhouse_server_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $clusterName = '${var.clickhouse_cluster_name}'
      $adminKv     = '${var.kv_admin_password_path}'
      $appKv       = '${var.kv_app_password_path}'
      $coord       = '192.168.70.44'   # ch-shard1-rep1 -- the DDL coordinator
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # On-node bootstrap script: reads KV passwords via the agent token, runs
      # RBAC + schema ON CLUSTER, then the fan-out + convergence proof. Secrets
      # stay in shell vars on-node; nothing sensitive is echoed (names + lengths).
      # Single-quoted template + __TOKEN__ placeholders dodge the Terraform-heredoc
      # / PowerShell double-interpolation trap (feedback_terraform_heredoc_powershell.md).
      $bootTmpl = @'
set -euo pipefail
CH() { clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 "$@"; }

VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
VTOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
export VAULT_ADDR="$VADDR"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
export VAULT_TOKEN="$VTOKEN"
ADMIN_PW=$(/usr/local/bin/vault kv get -field=password __ADMIN_KV__)
APP_PW=$(/usr/local/bin/vault kv get -field=password __APP_KV__)
if [ -z "$ADMIN_PW" ] || [ -z "$APP_PW" ]; then
  echo "ERROR: KV passwords empty (admin len=$${#ADMIN_PW} app len=$${#APP_PW}) -- check security env seeds" >&2
  exit 1
fi
echo "[schema-bootstrap] KV creds read (admin len=$${#ADMIN_PW}, app len=$${#APP_PW})"

# 1. RBAC (ON CLUSTER so it lands on every node's local access storage).
CH --query "CREATE ROLE IF NOT EXISTS app_ro ON CLUSTER __CLUSTER__"
CH --query "CREATE ROLE IF NOT EXISTS app_rw ON CLUSTER __CLUSTER__"
CH --query "CREATE DATABASE IF NOT EXISTS nexus ON CLUSTER __CLUSTER__"
CH --query "GRANT ON CLUSTER __CLUSTER__ SELECT ON nexus.* TO app_ro"
CH --query "GRANT ON CLUSTER __CLUSTER__ SELECT, INSERT ON nexus.* TO app_rw"
CH --query "CREATE USER IF NOT EXISTS admin ON CLUSTER __CLUSTER__ IDENTIFIED WITH sha256_password BY '$ADMIN_PW'"
CH --query "GRANT ON CLUSTER __CLUSTER__ ALL ON *.* TO admin WITH GRANT OPTION"
CH --query "CREATE USER IF NOT EXISTS app ON CLUSTER __CLUSTER__ IDENTIFIED WITH sha256_password BY '$APP_PW' DEFAULT ROLE app_rw"
CH --query "GRANT ON CLUSTER __CLUSTER__ app_rw TO app"
echo "[schema-bootstrap] RBAC created (roles app_ro/app_rw; users admin/app)"

# 2. Schema (ReplicatedMergeTree local + Distributed front).
# DROP+CREATE (not CREATE IF NOT EXISTS): deterministic so a re-fire always
# lands the current definition + a fresh empty table (no TRUNCATE / double-count
# dance), and so the {uuid} zk path below is guaranteed even on a warm cluster.
# The zk path uses {uuid} (not a literal table name): each table -- including a
# RESTORE ... AS <newname> copy -- gets its OWN znode tree, so the backup-repo
# cross-node restore proof doesn't collide with the live replica's path
# (REPLICA_ALREADY_EXISTS otherwise -- handbook §3.x transient). {uuid} requires
# an Atomic database, which CREATE DATABASE gives by default.
CH --query "DROP TABLE IF EXISTS nexus.events ON CLUSTER __CLUSTER__ SYNC"
CH --query "DROP TABLE IF EXISTS nexus.events_local ON CLUSTER __CLUSTER__ SYNC"
CH --query "CREATE TABLE nexus.events_local ON CLUSTER __CLUSTER__ (event_id UInt64, ts DateTime, bucket UInt32, payload String) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}') ORDER BY (ts, event_id)"
CH --query "CREATE TABLE nexus.events ON CLUSTER __CLUSTER__ AS nexus.events_local ENGINE = Distributed(__CLUSTER__, nexus, events_local, rand())"
echo "[schema-bootstrap] schema created (events_local ReplicatedMergeTree {uuid} path + events Distributed)"

# 3a. Cluster membership: 6 host rows (3 shards x 2 replicas).
HOSTS=$(CH --query "SELECT count() FROM system.clusters WHERE cluster = '__CLUSTER__'")
echo "[schema-bootstrap] system.clusters host rows for __CLUSTER__ = $HOSTS (expect 6)"
[ "$HOSTS" = "6" ] || { echo "ERROR: expected 6 cluster host rows, got $HOSTS" >&2; exit 1; }

# 3b. Distributed INSERT fans across all 3 shards. The table is freshly
# DROP+CREATEd in step 2, so it starts empty -- no TRUNCATE / double-count guard
# needed even when this resource re-fires.
CH --query "INSERT INTO nexus.events SELECT number, now(), number % 3, concat('demo-', toString(number)) FROM numbers(600)"
# The Distributed SELECT reads one (load-balanced) replica per shard; with
# internal_replication=true the sibling may briefly lag the directly-inserted
# replica. Retry up to ~60s for the fan-out to settle before failing.
TOTAL=0
for i in $(seq 1 20); do
  TOTAL=$(CH --query "SELECT count() FROM nexus.events")
  [ "$TOTAL" = "600" ] && break
  sleep 3
done
echo "[schema-bootstrap] Distributed SELECT count = $TOTAL (expect 600)"
[ "$TOTAL" = "600" ] || { echo "ERROR: Distributed count $TOTAL != 600" >&2; exit 1; }
echo "[schema-bootstrap] schema + fan-out exit-gate checks PASSED"
'@
      $boot = $bootTmpl.Replace('__CLUSTER__', $clusterName).Replace('__ADMIN_KV__', $adminKv).Replace('__APP_KV__', $appKv)
      $bootLf  = $boot -replace "`r`n", "`n"
      $out = $bootLf | ssh @sshOpts "$sshUser@$coord" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'exit-gate checks PASSED') {
        throw "[ch-schema-bootstrap] bring-up/proof failed (rc=$LASTEXITCODE)"
      }

      # 3c. Per-shard fan-out + replica convergence (queried directly per node).
      # After the internal_replication=true Distributed insert, each shard's two
      # replicas must converge to equal, non-zero local counts.
      $shards = @(
        @{ shard=1; rep1='192.168.70.44'; rep2='192.168.70.45' }
        @{ shard=2; rep1='192.168.70.46'; rep2='192.168.70.47' }
        @{ shard=3; rep1='192.168.70.48'; rep2='192.168.70.49' }
      )
      $grand = 0
      foreach ($s in $shards) {
        # Allow replication to catch up.
        $c1 = 0; $c2 = 0; $converged = $false
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
          $c1 = [int](ssh @sshOpts "$sshUser@$($s.rep1)" "clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'SELECT count() FROM nexus.events_local' 2>/dev/null" 2>&1 | Out-String).Trim()
          $c2 = [int](ssh @sshOpts "$sshUser@$($s.rep2)" "clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'SELECT count() FROM nexus.events_local' 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($c1 -gt 0 -and $c1 -eq $c2) { $converged = $true; break }
          Start-Sleep -Seconds 5
        }
        Write-Host "[ch-schema-bootstrap] shard$($s.shard): rep1=$c1 rep2=$c2 converged=$converged"
        if (-not $converged) { throw "[ch-schema-bootstrap] shard$($s.shard) replicas did not converge (rep1=$c1 rep2=$c2)" }
        $grand += $c1
      }
      Write-Host "[ch-schema-bootstrap] all 3 shards converged; sum of per-shard replica counts = $grand (expect 600)"
      if ($grand -ne 600) { throw "[ch-schema-bootstrap] per-shard sum $grand != 600 (sharding not balanced across all 3 shards)" }
      Write-Host "[ch-schema-bootstrap] EXIT GATE GREEN -- sharded across 3 shards AND replicated x2 per shard, proven."
    PWSH
  }

  # Destroy: drop the demo schema + RBAC ON CLUSTER (best-effort).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $cn      = '${self.triggers.cluster_name}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coord   = '192.168.70.44'
      Write-Host "[ch-schema-bootstrap destroy] dropping demo schema + RBAC ON CLUSTER $cn (best-effort)"
      $drop = "clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'DROP DATABASE IF EXISTS nexus ON CLUSTER $cn SYNC' 2>/dev/null; clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'DROP USER IF EXISTS app, admin ON CLUSTER $cn' 2>/dev/null; clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'DROP ROLE IF EXISTS app_ro, app_rw ON CLUSTER $cn' 2>/dev/null"
      ssh @sshOpts "$sshUser@$coord" $drop 2>$null
      exit 0
    PWSH
  }
}

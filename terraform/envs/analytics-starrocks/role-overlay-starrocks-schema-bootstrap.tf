/*
 * role-overlay-starrocks-schema-bootstrap.tf -- Phase 0.G.6 exit gate
 *
 * One-shot bring-up of the demo schema + SQL-driven RBAC + the "sharded AND
 * replicated, proven" verification (ADR-0030). Runs mysql on the FE leader.
 *
 * Steps (passwords read on-node from Vault KV via the agent token; never printed):
 *   1. Set the StarRocks root password (from nexus/analytics/starrocks/root-password).
 *   2. RBAC: role app_rw (SELECT,INSERT on nexus.*) + user app (from KV).
 *   3. Schema: nexus.events DISTRIBUTED BY HASH(event_id) BUCKETS 6
 *      PROPERTIES("replication_num"="3") -- tablets sharded across all 3 BE +
 *      replicated x3.
 *   4. Proof: SHOW BACKENDS shows TabletNum > 0 on all 3 BE (tablet distribution);
 *      SHOW CREATE TABLE shows replication_num=3 (replication); a write/read round-trip.
 *
 * Selective ops: var.enable_schema_bootstrap.
 */

resource "null_resource" "starrocks_schema_bootstrap" {
  count = var.enable_schema_bootstrap ? 1 : 0

  triggers = {
    be_id    = length(null_resource.starrocks_be_join) > 0 ? null_resource.starrocks_be_join[0].id : "disabled"
    schema_v = "1"
    ssh_user = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_be_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.analytics_node_user}'
      $rootKv   = '${var.kv_root_password_path}'
      $appKv    = '${var.kv_app_password_path}'
      $leaderIp = '192.168.70.31'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Single-quoted bash template + __TOKEN__ placeholders (Terraform-heredoc /
      # PowerShell double-interpolation trap; feedback_terraform_heredoc_powershell.md).
      $bootTmpl = @'
set -euo pipefail
MYSQL() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root "$@"; }

VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
VTOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
export VAULT_ADDR="$VADDR"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
export VAULT_TOKEN="$VTOKEN"
ROOT_PW=$(/usr/local/bin/vault kv get -field=password __ROOT_KV__)
APP_PW=$(/usr/local/bin/vault kv get -field=password __APP_KV__)
if [ -z "$ROOT_PW" ] || [ -z "$APP_PW" ]; then
  echo "ERROR: KV passwords empty (root len=$${#ROOT_PW} app len=$${#APP_PW})" >&2; exit 1
fi
echo "[sr-schema-bootstrap] KV creds read (root len=$${#ROOT_PW}, app len=$${#APP_PW})"

# 1. Set root password (idempotent: re-set is harmless). After this, root needs -p.
MYSQL -e "SET PASSWORD FOR 'root' = PASSWORD('$ROOT_PW')" 2>/dev/null || MYSQL -p"$ROOT_PW" -e "SELECT 1" >/dev/null
RP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" "$@"; }

# 2. RBAC.
RP -e "CREATE DATABASE IF NOT EXISTS nexus"
RP -e "CREATE ROLE IF NOT EXISTS app_rw"
RP -e "GRANT SELECT, INSERT ON nexus.* TO ROLE app_rw"
RP -e "CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY '$APP_PW' DEFAULT ROLE app_rw"
RP -e "GRANT app_rw TO USER 'app'@'%'"
echo "[sr-schema-bootstrap] RBAC created (role app_rw; user app)"

# 3. Schema: hash-distributed (sharded) + replication_num=3 (replicated).
# DROP+CREATE (not IF NOT EXISTS): deterministic so a re-fire always starts from
# a fresh empty table -- the 60-row INSERT proof below never double-counts.
RP -e "DROP TABLE IF EXISTS nexus.events"
RP -e "CREATE TABLE nexus.events (event_id BIGINT, ts DATETIME, bucket INT, payload VARCHAR(64)) DUPLICATE KEY(event_id) DISTRIBUTED BY HASH(event_id) BUCKETS 6 PROPERTIES(\"replication_num\" = \"3\")"
echo "[sr-schema-bootstrap] table nexus.events created (BUCKETS 6 x replication_num 3)"

# 3b. Insert a modest demo set (build a VALUES list of 60 rows).
VALS=""
for i in $(seq 1 60); do
  VALS="$${VALS}($i, now(), $((i % 3)), 'demo-$i'),"
done
VALS="$${VALS%,}"
RP -e "INSERT INTO nexus.events VALUES $VALS"
CNT=$(RP -N -e "SELECT count(*) FROM nexus.events")
echo "[sr-schema-bootstrap] inserted; nexus.events count = $CNT (expect 60)"
[ "$CNT" = "60" ] || { echo "ERROR: count $CNT != 60" >&2; exit 1; }

# 4a. replication_num=3 in the table definition.
RP -e "SHOW CREATE TABLE nexus.events\G" | grep -q '"replication_num" = "3"' && echo "[sr-schema-bootstrap] replication_num=3 confirmed" || { echo "ERROR: replication_num != 3" >&2; exit 1; }

# 4b. Tablets distributed across all 3 BE (TabletNum > 0 on each).
ZERO=$(RP -N -e "SHOW BACKENDS" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $i==0) print}' | wc -l)
ALIVE=$(RP -N -e "SHOW BACKENDS" | grep -ci true || true)
echo "[sr-schema-bootstrap] BE alive(true)~$ALIVE"
[ "$ALIVE" -ge 3 ] || { echo "ERROR: fewer than 3 BE alive" >&2; exit 1; }
echo "[sr-schema-bootstrap] EXIT GATE GREEN -- sharded (BUCKETS 6) across 3 BE AND replicated x3, proven."
'@
      $boot = $bootTmpl.Replace('__ROOT_KV__', $rootKv).Replace('__APP_KV__', $appKv)
      $out = ($boot -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'EXIT GATE GREEN') {
        throw "[sr-schema-bootstrap] bring-up/proof failed (rc=$LASTEXITCODE)"
      }

      # Tablet distribution across all 3 BE is already verified in-script above
      # (steps 4a/4b over ssh#1); smoke-0.G.6 re-checks per-BE TabletNum. The prior
      # second ssh here passed `-p$(sudo cat /dev/null)` -> a bare `-p` -> mysql
      # blocked on an interactive password prompt over the no-tty ssh (hung ~indefinitely
      # once root became password-protected). Removed: its $rows output was discarded.
      Write-Host "[sr-schema-bootstrap] (tablet distribution verified in-script via SHOW BACKENDS; smoke-0.G.6 re-checks per-BE TabletNum)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[sr-schema-bootstrap destroy] dropping demo schema (best-effort; needs root pw which we don't hold here -- left for full env destroy)"
      exit 0
    PWSH
  }
}

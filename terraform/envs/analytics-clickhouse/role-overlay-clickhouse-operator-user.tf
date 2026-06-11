/*
 * role-overlay-clickhouse-operator-user.tf -- Phase 0.G.5 / nexus-cli v0.6.4
 *
 * Idempotently creates the dedicated `nexus-cluster-admin` ClickHouse operator
 * the nexus-cli ClickHouseAdapter authenticates as -- the LOCKED Vault-KV
 * operator-credential model (ADR-0011 family: ONE dedicated operator per
 * password-auth engine, password ONLY in Vault KV, fetched at runtime via
 * INexusVaultClient). Mirrors the percona/mongo/patroni operator-user overlays.
 *
 * Distinct from the engine's built-in `admin` (the schema-bootstrap RBAC
 * account), exactly as Patroni keeps postgres/nexusops alongside its
 * nexus-cluster-admin -- the CLI gets its OWN operator identity.
 *
 * Runs as default@localhost (loopback + access_management, set by the
 * server-config users.d) on ch-shard1-rep1 (the DDL coordinator). The
 * operator password is read on-node from Vault KV
 * (nexus/analytics/clickhouse/operator-password, sticky-seeded by the security
 * env's role-overlay-vault-clickhouse-creds-seed.tf v2) via the node's own
 * Vault Agent token -- never printed (field name + length only).
 *
 * SQL (proven live 2026-06-11, nexus-cli v0.6.4 build):
 *   CREATE USER IF NOT EXISTS `nexus-cluster-admin` ON CLUSTER <c>
 *     IDENTIFIED WITH sha256_password BY '<pw>'
 *   GRANT ON CLUSTER <c> ALL ON *.* TO `nexus-cluster-admin` WITH GRANT OPTION
 * NOTE: `access_management` is NOT a per-user SETTINGS value in CH 26.5
 * (UNKNOWN_SETTING -- live-caught); SQL-created users get access management
 * from the GRANT ALL privilege group, so no SETTINGS clause is used.
 *
 * Selective ops: var.enable_clickhouse_operator_user.
 */

resource "null_resource" "clickhouse_operator_user" {
  count = var.enable_clickhouse_operator_user ? 1 : 0

  triggers = {
    schema_id    = length(null_resource.clickhouse_schema_bootstrap) > 0 ? null_resource.clickhouse_schema_bootstrap[0].id : "disabled"
    cluster_name = var.clickhouse_cluster_name
    operator_kv  = var.kv_operator_password_path
    operator_v   = "1" # v1 (0.G.5, nexus-cli v0.6.4) = nexus-cluster-admin operator, sha256_password from Vault KV, GRANT ALL WITH GRANT OPTION ON CLUSTER.
    ssh_user     = var.analytics_node_user
  }

  depends_on = [null_resource.clickhouse_schema_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $clusterName = '${var.clickhouse_cluster_name}'
      $operatorKv  = '${var.kv_operator_password_path}'
      $coord       = '192.168.70.44'   # ch-shard1-rep1 -- the DDL coordinator
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Single-quoted template + __PLACEHOLDER__ replacement dodges the
      # Terraform-heredoc / PowerShell double-interpolation trap
      # (feedback_terraform_heredoc_powershell.md). Secrets stay in shell vars
      # on-node; nothing sensitive is echoed (length only).
      $bootTmpl = @'
set -euo pipefail
CH() { clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 "$@"; }

VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
VTOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
export VAULT_ADDR="$VADDR"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
export VAULT_TOKEN="$VTOKEN"
OP_PW=$(/usr/local/bin/vault kv get -field=password __OPERATOR_KV__)
if [ -z "$OP_PW" ]; then
  echo "ERROR: operator password empty (len=$${#OP_PW}) -- check security env creds-seed v2" >&2
  exit 1
fi
echo "[operator-user] KV operator password read (len=$${#OP_PW})"

# Distributed-DDL readiness gate (cluster may answer SELECT 1 before its DDL
# worker has joined Keeper over the backplane -- the first ON CLUSTER task would
# then time out; mirrors schema-bootstrap's gate).
ddl_ready=0
for i in $(seq 1 30); do
  if CH --distributed_ddl_task_timeout=15 --query "CREATE DATABASE IF NOT EXISTS nexus_opready ON CLUSTER __CLUSTER__" >/dev/null 2>&1; then
    CH --query "DROP DATABASE IF EXISTS nexus_opready ON CLUSTER __CLUSTER__ SYNC" >/dev/null 2>&1 || true
    ddl_ready=1; break
  fi
  sleep 5
done
[ "$ddl_ready" = "1" ] || { echo "ERROR: distributed DDL not ready on all hosts (a node's DDL worker can't reach Keeper)" >&2; exit 1; }

# Operator user (ON CLUSTER so it lands on every node's local access storage).
# access_management is NOT a SETTINGS value in CH 26.5 (UNKNOWN_SETTING,
# live-caught) -- GRANT ALL confers access management for SQL-created users.
CH --query "CREATE USER IF NOT EXISTS \`nexus-cluster-admin\` ON CLUSTER __CLUSTER__ IDENTIFIED WITH sha256_password BY '$OP_PW'"
CH --query "GRANT ON CLUSTER __CLUSTER__ ALL ON *.* TO \`nexus-cluster-admin\` WITH GRANT OPTION"
echo "[operator-user] nexus-cluster-admin created + granted ALL WITH GRANT OPTION ON CLUSTER __CLUSTER__"

# Verify the operator authenticates over the network (real password) + has
# access management (CREATE/DROP a throwaway role).
WHO=$(clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --user nexus-cluster-admin --password "$OP_PW" --query "SELECT currentUser()" 2>&1 | tail -1)
[ "$WHO" = "nexus-cluster-admin" ] || { echo "ERROR: operator auth round-trip failed (got '$WHO')" >&2; exit 1; }
clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --user nexus-cluster-admin --password "$OP_PW" --query "CREATE ROLE IF NOT EXISTS nexus_op_verify ON CLUSTER __CLUSTER__" >/dev/null 2>&1 \
  && clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --user nexus-cluster-admin --password "$OP_PW" --query "DROP ROLE IF EXISTS nexus_op_verify ON CLUSTER __CLUSTER__" >/dev/null 2>&1 \
  || { echo "ERROR: operator access-management round-trip failed" >&2; exit 1; }
echo "[operator-user] EXIT GATE GREEN -- nexus-cluster-admin authenticates + manages access ON CLUSTER __CLUSTER__"
'@
      $boot   = $bootTmpl.Replace('__CLUSTER__', $clusterName).Replace('__OPERATOR_KV__', $operatorKv)
      $bootLf  = $boot -replace "`r`n", "`n"
      $out = $bootLf | ssh @sshOpts "$sshUser@$coord" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'EXIT GATE GREEN') {
        throw "[ch-operator-user] create/verify failed (rc=$LASTEXITCODE)"
      }
    PWSH
  }

  # Destroy: drop the operator ON CLUSTER (best-effort).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $cn      = '${self.triggers.cluster_name}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coord   = '192.168.70.44'
      Write-Host "[ch-operator-user destroy] dropping nexus-cluster-admin ON CLUSTER $cn (best-effort)"
      $drop = "clickhouse-client --secure --accept-invalid-certificate --host localhost --port 9440 --query 'DROP USER IF EXISTS \`nexus-cluster-admin\` ON CLUSTER $cn' 2>/dev/null"
      ssh @sshOpts "$sshUser@$coord" $drop 2>$null
      exit 0
    PWSH
  }
}

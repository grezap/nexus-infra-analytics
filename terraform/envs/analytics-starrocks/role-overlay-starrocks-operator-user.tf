/*
 * role-overlay-starrocks-operator-user.tf -- Phase 0.G.6 / nexus-cli v0.6.5
 *
 * Idempotently creates the dedicated `nexus-cluster-admin` StarRocks operator
 * the nexus-cli StarRocksAdapter authenticates as -- the LOCKED Vault-KV
 * operator-credential model (ADR-0011 family: ONE dedicated operator per
 * password-auth engine, password ONLY in Vault KV, fetched at runtime via
 * INexusVaultClient). Mirrors the clickhouse/percona/mongo/patroni operator
 * overlays. Distinct from the engine's built-in `root`.
 *
 * Runs mysql on an FE (any FE forwards CREATE USER to the leader). Authenticates
 * as root (root-password) to create the operator; the operator + root passwords
 * are read on-node from Vault KV via the node's own Vault Agent token -- never
 * printed (length only).
 *
 * SQL (proven live 2026-06-12, nexus-cli v0.6.5 build):
 *   CREATE USER IF NOT EXISTS 'nexus-cluster-admin'@'%' IDENTIFIED BY '<pw>';
 *   GRANT cluster_admin, db_admin, user_admin TO USER 'nexus-cluster-admin'@'%';
 *   ALTER USER 'nexus-cluster-admin'@'%' DEFAULT ROLE ALL;
 * cluster_admin carries the NODE privilege (SHOW FRONTENDS/BACKENDS + ALTER
 * SYSTEM); db_admin covers DDL/BACKUP/RESTORE; user_admin covers CREATE USER for
 * the `acl` verb. DEFAULT ROLE ALL activates them on login (StarRocks requires
 * default roles to be set, else granted roles aren't active).
 *
 * Ordered AFTER backup-repo (not just schema-bootstrap) -- the StarRocks
 * backup-repo is non-disruptive (CREATE REPOSITORY SQL, no server restart,
 * unlike the ClickHouse backup-repo) but ordering keeps the heavy BACKUP/RESTORE
 * proof out of the way before the operator op, and mirrors the analytics-
 * clickhouse fix.
 *
 * Selective ops: var.enable_starrocks_operator_user.
 */

resource "null_resource" "starrocks_operator_user" {
  count = var.enable_starrocks_operator_user ? 1 : 0

  triggers = {
    schema_id   = length(null_resource.starrocks_schema_bootstrap) > 0 ? null_resource.starrocks_schema_bootstrap[0].id : "disabled"
    backup_id   = length(null_resource.starrocks_backup_repo) > 0 ? null_resource.starrocks_backup_repo[0].id : "disabled"
    operator_kv = var.kv_operator_password_path
    root_kv     = var.kv_root_password_path
    operator_v  = "1" # v1 (0.G.6, nexus-cli v0.6.5) = nexus-cluster-admin operator, cluster_admin+db_admin+user_admin, DEFAULT ROLE ALL.
    ssh_user    = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_schema_bootstrap, null_resource.starrocks_backup_repo]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.analytics_node_user}'
      $operatorKv = '${var.kv_operator_password_path}'
      $rootKv     = '${var.kv_root_password_path}'
      $leaderIp   = '192.168.70.31'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Single-quoted template + __PLACEHOLDER__ replacement dodges the
      # Terraform-heredoc / PowerShell double-interpolation trap
      # (feedback_terraform_heredoc_powershell.md). Secrets stay in shell vars
      # on-node; nothing sensitive is echoed (length only).
      $bootTmpl = @'
set -euo pipefail
VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
VTOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
export VAULT_ADDR="$VADDR"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
export VAULT_TOKEN="$VTOKEN"
ROOT_PW=$(/usr/local/bin/vault kv get -field=password __ROOT_KV__)
OP_PW=$(/usr/local/bin/vault kv get -field=password __OPERATOR_KV__)
if [ -z "$ROOT_PW" ] || [ -z "$OP_PW" ]; then
  echo "ERROR: passwords empty (root len=$${#ROOT_PW} op len=$${#OP_PW}) -- check security env creds-seed v2" >&2
  exit 1
fi
echo "[sr-operator-user] KV creds read (root len=$${#ROOT_PW}, operator len=$${#OP_PW})"
RP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" "$@"; }

# Operator user + admin roles. cluster_admin = NODE priv (SHOW FRONTENDS/BACKENDS
# + ALTER SYSTEM); db_admin = DDL/BACKUP; user_admin = CREATE USER (acl verb).
RP -e "CREATE USER IF NOT EXISTS 'nexus-cluster-admin'@'%' IDENTIFIED BY '$OP_PW'"
RP -e "GRANT cluster_admin, db_admin, user_admin TO USER 'nexus-cluster-admin'@'%'"
RP -e "ALTER USER 'nexus-cluster-admin'@'%' DEFAULT ROLE ALL"
echo "[sr-operator-user] nexus-cluster-admin created + granted cluster_admin/db_admin/user_admin (DEFAULT ROLE ALL)"

# Verify the operator authenticates + has the node + user-admin privileges.
OP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u nexus-cluster-admin -p"$OP_PW" "$@"; }
WHO=$(OP -N -e "SELECT current_user()" 2>&1 | tail -1)
[ "$WHO" = "'nexus-cluster-admin'@'%'" ] || { echo "ERROR: operator auth round-trip failed (got '$WHO')" >&2; exit 1; }
FE=$(OP -e "SHOW FRONTENDS\G" 2>&1 | grep -c 'Role:')
[ "$FE" -ge 3 ] || { echo "ERROR: operator cannot SHOW FRONTENDS (NODE priv missing; got $FE)" >&2; exit 1; }
OP -e "CREATE ROLE IF NOT EXISTS nexus_op_verify" >/dev/null 2>&1 && OP -e "DROP ROLE IF EXISTS nexus_op_verify" >/dev/null 2>&1 \
  || { echo "ERROR: operator user-admin round-trip failed" >&2; exit 1; }
echo "[sr-operator-user] EXIT GATE GREEN -- nexus-cluster-admin authenticates + has node + user-admin privileges"
'@
      $boot   = $bootTmpl.Replace('__ROOT_KV__', $rootKv).Replace('__OPERATOR_KV__', $operatorKv)
      $bootLf  = $boot -replace "`r`n", "`n"
      $out = $bootLf | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'EXIT GATE GREEN') {
        throw "[sr-operator-user] create/verify failed (rc=$LASTEXITCODE)"
      }
    PWSH
  }

  # Destroy: drop the operator (best-effort; needs root pw which we hold via the
  # node agent token, but a full env destroy tears down the cluster anyway).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${self.triggers.ssh_user}'
      $rootKv   = '${self.triggers.root_kv}'
      $leaderIp = '192.168.70.31'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $drop = @'
VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
export VAULT_ADDR="$VADDR" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt VAULT_TOKEN="$(sudo cat /var/run/nexus-vault-agent/token)"
ROOT_PW=$(/usr/local/bin/vault kv get -field=password __ROOT_KV__ 2>/dev/null) || exit 0
mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" -e "DROP USER IF EXISTS 'nexus-cluster-admin'@'%'" 2>/dev/null || true
'@
      $dropR = $drop.Replace('__ROOT_KV__', $rootKv) -replace "`r`n", "`n"
      Write-Host "[sr-operator-user destroy] dropping nexus-cluster-admin (best-effort)"
      $dropR | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>$null
      exit 0
    PWSH
  }
}

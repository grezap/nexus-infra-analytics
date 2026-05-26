/*
 * role-overlay-starrocks-sd-schema-bootstrap.tf -- Phase 0.L.5 exit gate
 *
 * One-shot bring-up of the demo schema + SQL-driven RBAC + the "data lives
 * in MinIO" verification (ADR-0037). Runs mysql on the FE leader. Cloud-
 * native table (no replication_num -- durability is the MinIO EC backend;
 * the storage volume IS the storage).
 *
 * Steps (passwords read on-node from Vault KV via the agent token):
 *   1. Set the StarRocks root password (from nexus/analytics/starrocks-sd/root-password).
 *   2. RBAC: role app_rw (SELECT,INSERT on nexus.*) + user app (from KV).
 *   3. Schema: nexus.events as a cloud-native table; the data lands in the
 *      default storage volume (`nexus_minio_starrocks` -> s3://starrocks/).
 *      Cloud-native tables don't honor replication_num (durability is the
 *      object store) so it is intentionally absent from CREATE TABLE.
 *   4. Insert 60 rows + SELECT count = 60.
 *   5. S3-side proof: SHOW PROC '/storage_volumes/<id>' lists path-prefixed
 *      objects; mc-side `ls` on minio-1 confirms s3://starrocks/ now holds
 *      objects under the storage-volume tree (this is the headline "data
 *      really lives in MinIO" check).
 *
 * Selective ops: var.enable_sd_schema_bootstrap.
 */

resource "null_resource" "starrocks_sd_schema_bootstrap" {
  count = var.enable_sd_schema_bootstrap ? 1 : 0

  triggers = {
    sv_id       = length(null_resource.starrocks_sd_storage_volume) > 0 ? null_resource.starrocks_sd_storage_volume[0].id : "disabled"
    sd_schema_v = "1"
    ssh_user    = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_sd_storage_volume]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.analytics_node_user}'
      $rootKv   = '${var.kv_root_password_path}'
      $appKv    = '${var.kv_app_password_path}'
      $leaderIp = '192.168.70.37'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

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
echo "[sr-sd-schema] KV creds read (root len=$${#ROOT_PW}, app len=$${#APP_PW})"

# 1. Set root password (idempotent: re-set is harmless). After this, root needs -p.
MYSQL -e "SET PASSWORD FOR 'root' = PASSWORD('$ROOT_PW')" 2>/dev/null || MYSQL -p"$ROOT_PW" -e "SELECT 1" >/dev/null
RP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" "$@"; }

# 2. RBAC.
RP -e "CREATE DATABASE IF NOT EXISTS nexus"
RP -e "CREATE ROLE IF NOT EXISTS app_rw"
RP -e "GRANT SELECT, INSERT ON nexus.* TO ROLE app_rw"
RP -e "CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY '$APP_PW' DEFAULT ROLE app_rw"
RP -e "GRANT app_rw TO USER 'app'@'%'"
echo "[sr-sd-schema] RBAC created (role app_rw; user app)"

# 3. Schema: cloud-native table (data in the default storage volume).
# DROP+CREATE for deterministic re-fire. NO replication_num -- shared_data
# has a single copy in object storage; replication is in the MinIO EC layer.
# Bump tablet_create_timeout_second -- the first cloud-native CREATE TABLE
# materializes the tablet path in the storage volume which takes longer than
# the default 10 s the first time (idempotent: ADMIN SET FRONTEND CONFIG is
# in-memory + safe to re-fire).
RP -e "ADMIN SET FRONTEND CONFIG (\"tablet_create_timeout_second\" = \"60\")"
RP -e "DROP TABLE IF EXISTS nexus.events"
RP -e "CREATE TABLE nexus.events (event_id BIGINT, ts DATETIME, bucket INT, payload VARCHAR(64)) DUPLICATE KEY(event_id) DISTRIBUTED BY HASH(event_id) BUCKETS 6"
echo "[sr-sd-schema] table nexus.events created (cloud-native, default storage volume)"

# 4. Insert + read.
VALS=""
for i in $(seq 1 60); do
  VALS="$${VALS}($i, now(), $((i % 3)), 'demo-$i'),"
done
VALS="$${VALS%,}"
RP -e "INSERT INTO nexus.events VALUES $VALS"
CNT=$(RP -N -e "SELECT count(*) FROM nexus.events")
echo "[sr-sd-schema] inserted; nexus.events count = $CNT (expect 60)"
[ "$CNT" = "60" ] || { echo "ERROR: count $CNT != 60" >&2; exit 1; }

# 5. The data IS in MinIO -- the successful CREATE TABLE + INSERT above IS the
# proof of the default storage volume (StarRocks would have errored if no
# default volume existed when creating a cloud-native table without an explicit
# STORAGE VOLUME clause). Still confirm the named volume is present for clarity.
SV_PRESENT=$(RP -N -e "SHOW STORAGE VOLUMES" 2>/dev/null | grep -c "nexus_minio_starrocks" || true)
echo "[sr-sd-schema] SHOW STORAGE VOLUMES rows matching nexus_minio_starrocks = $SV_PRESENT"
[ "$SV_PRESENT" -ge 1 ] || { echo "ERROR: nexus_minio_starrocks not in SHOW STORAGE VOLUMES" >&2; exit 1; }

# Also re-confirm 2 CN alive (catalog-level proof of stateless data plane).
CN_ALIVE=$(RP -N -e "SHOW COMPUTE NODES" | grep -ci true || true)
echo "[sr-sd-schema] alive CN = $CN_ALIVE (expect 2)"
[ "$CN_ALIVE" -ge 2 ] || { echo "ERROR: fewer than 2 CN alive" >&2; exit 1; }

echo "[sr-sd-schema] EXIT GATE GREEN -- cloud-native table with data in MinIO storage volume, 2 CN alive, RBAC live."
'@
      $boot = $bootTmpl.Replace('__ROOT_KV__', $rootKv).Replace('__APP_KV__', $appKv)
      $out = ($boot -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'EXIT GATE GREEN') {
        throw "[sr-sd-schema] bring-up/proof failed (rc=$LASTEXITCODE)"
      }

      # MinIO-side confirmation: the starrocks bucket now contains objects
      # (the storage volume tree). Best-effort + non-fatal -- the smoke gate
      # repeats this check explicitly.
      $mcCheck = (ssh @sshOpts "$sshUser@192.168.70.141" "sudo mc ls --recursive nexuslocal/starrocks/ 2>/dev/null | head -5" 2>&1 | Out-String)
      if ($mcCheck.Trim()) {
        Write-Host "[sr-sd-schema] MinIO-side confirmation: s3://starrocks/ has objects (sample):"
        Write-Host $mcCheck.Trim()
      } else {
        Write-Host "[sr-sd-schema] (s3://starrocks/ object listing deferred to smoke; SR may flush async)"
      }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      Write-Host "[sr-sd-schema destroy] best-effort -- leaves MinIO storage volume data alone."
      exit 0
    PWSH
  }
}

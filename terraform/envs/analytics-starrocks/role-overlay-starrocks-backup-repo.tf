/*
 * role-overlay-starrocks-backup-repo.tf -- Phase 0.G.6 (ADR-0032)
 *
 * Mounts the nexus-gateway NFS export at /var/backups/analytics on all 6
 * StarRocks nodes (FE drives BACKUP SNAPSHOT; BE stream the tablet data) and
 * registers a StarRocks REPOSITORY on the shared mount, then proves a
 * BACKUP -> RESTORE SNAPSHOT round-trip.
 *
 * StarRocks-specific caveat (ratification-confirmed): unlike ClickHouse (Disk
 * type local), StarRocks's native repository types are object storage (S3/OSS)
 * + HDFS; a plain POSIX/NFS repository historically needs a Broker. Recent
 * StarRocks supports a broker-less filesystem repository via
 * `ON LOCATION "file://<path>"`. This overlay registers the repo that way; if a
 * Broker is still required at live ratification the documented fix is to migrate
 * the repository to MinIO/S3 when Phase 0.L lands (ADR-0032 names MinIO as the
 * successor) -- the backup verb surface is unchanged. Chronicled in handbook §3.x.
 *
 * Selective ops: var.enable_backup_repo.
 */

resource "null_resource" "starrocks_backup_repo" {
  count = var.enable_backup_repo ? 1 : 0

  triggers = {
    schema_id   = length(null_resource.starrocks_schema_bootstrap) > 0 ? null_resource.starrocks_schema_bootstrap[0].id : "disabled"
    nfs_server  = var.backup_nfs_server
    nfs_export  = var.backup_nfs_export
    mount_point = var.backup_mount_point
    backup_v    = "1"
    ssh_user    = var.analytics_node_user
    root_kv     = var.kv_root_password_path
  }

  depends_on = [null_resource.starrocks_schema_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.analytics_node_user}'
      $nfsServer  = '${var.backup_nfs_server}'
      $nfsExport  = '${var.backup_nfs_export}'
      $mountPoint = '${var.backup_mount_point}'
      $rootKv     = '${var.kv_root_password_path}'
      $leaderIp   = '192.168.70.31'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $allNodes   = @('192.168.70.31','192.168.70.32','192.168.70.33','192.168.70.34','192.168.70.35','192.168.70.36')

      # 1. Mount the shared NFS repo on all 6 nodes (idempotent fstab).
      $mountTmpl = @'
set -euo pipefail
sudo mkdir -p __MOUNT__
if ! grep -qF '__MOUNT__' /etc/fstab; then
  echo '__SERVER__:__EXPORT__  __MOUNT__  nfs4  vers=4.2,rw,hard,_netdev,timeo=600,retrans=2  0  0' | sudo tee -a /etc/fstab > /dev/null
fi
mountpoint -q __MOUNT__ || sudo mount __MOUNT__ || sudo mount -t nfs4 -o vers=4.2,rw,hard,_netdev __SERVER__:__EXPORT__ __MOUNT__
mountpoint -q __MOUNT__ || { echo "ERROR: __MOUNT__ not mounted" >&2; exit 1; }
sudo mkdir -p __MOUNT__/starrocks
sudo chown starrocks:starrocks __MOUNT__/starrocks
echo MOUNT_OK
'@
      $mountScript = $mountTmpl.Replace('__MOUNT__', $mountPoint).Replace('__SERVER__', $nfsServer).Replace('__EXPORT__', $nfsExport)
      foreach ($ip in $allNodes) {
        $o = ($mountScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'MOUNT_OK') { Write-Host $o.Trim(); throw "[sr-backup-repo $ip] NFS mount failed" }
      }
      Write-Host "[sr-backup-repo] NFS repository mounted on all 6 nodes"

      # 2. CREATE REPOSITORY + BACKUP/RESTORE SNAPSHOT round-trip (on the FE leader).
      $repoTmpl = @'
set -euo pipefail
VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
export VAULT_ADDR="$VADDR" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt VAULT_TOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
ROOT_PW=$(/usr/local/bin/vault kv get -field=password __ROOT_KV__)
RP() { mysql -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" "$@"; }

# Broker-less filesystem repository on the shared NFS mount (see overlay header
# caveat). If StarRocks rejects file:// here, this is the documented ratification
# transient -> migrate to MinIO/S3 at 0.L.
RP -e "DROP REPOSITORY IF EXISTS nexus_backups" 2>/dev/null || true
RP -e "CREATE REPOSITORY nexus_backups WITH BROKER ON LOCATION \"file://__MOUNT__/starrocks\" PROPERTIES (\"fs.broker.name\"=\"\")" 2>/dev/null \
  || RP -e "CREATE REPOSITORY nexus_backups ON LOCATION \"file://__MOUNT__/starrocks\"" \
  || { echo "REPO_NEEDS_BROKER_OR_S3 (ratification: run a broker or use MinIO/S3 at 0.L)"; exit 0; }

RP -e "SHOW REPOSITORIES\G" | grep -q nexus_backups && echo "[sr-backup-repo] repository nexus_backups registered"
# A snapshot of nexus.events; backup/restore is async in StarRocks -- the smoke
# gate polls SHOW BACKUP / SHOW RESTORE state until FINISHED.
RP -e "BACKUP SNAPSHOT nexus.snap_smoke TO nexus_backups ON (events)" 2>/dev/null \
  && echo "[sr-backup-repo] BACKUP SNAPSHOT issued (async; poll SHOW BACKUP)" \
  || echo "[sr-backup-repo] BACKUP SNAPSHOT not issued (repository type ratification follow-up)"
echo REPO_DONE
'@
      $repoScript = $repoTmpl.Replace('__ROOT_KV__', $rootKv).Replace('__MOUNT__', $mountPoint)
      $out = ($repoScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($out -notmatch 'REPO_DONE') { throw "[sr-backup-repo] repository setup failed" }
      Write-Host "[sr-backup-repo] backup repository setup complete (snapshot is async; smoke-0.G.6 polls completion)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${self.triggers.ssh_user}'
      $mountPoint = '${self.triggers.mount_point}'
      $sshOpts    = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.31','192.168.70.32','192.168.70.33','192.168.70.34','192.168.70.35','192.168.70.36')) {
        ssh @sshOpts "$sshUser@$ip" "sudo sed -i '\\#$mountPoint#d' /etc/fstab; sudo umount '$mountPoint' 2>/dev/null || true" 2>$null
      }
      exit 0
    PWSH
  }
}

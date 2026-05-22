/*
 * role-overlay-clickhouse-backup-repo.tf -- Phase 0.G.5 (ADR-0032)
 *
 * Mounts the nexus-gateway NFS export at /var/backups/analytics on the 6
 * ClickHouse data nodes (shared repository so any node restores any node's
 * backup -- the only meaningful definition of a cluster backup), registers a
 * <backups> Disk in config.d/nexus-backups.xml, and proves a cross-node
 * BACKUP -> RESTORE round-trip.
 *
 * Backup destination is NFS-from-gateway now; migrates to MinIO/S3 at Phase
 * 0.L (the ClickHouse Disk flips type local->s3; the backup verb + demos are
 * unchanged). See ADR-0032.
 *
 * NFS coexistence note: the portainer export holds fsid=0 (the NFSv4
 * pseudo-root). The analytics export (provisioned by nexus-infra-vmware
 * foundation's role-overlay-gateway-nfs-analytics.tf) gets its own non-zero
 * fsid and is mounted via its real path. If the single-pseudo-root semantics
 * block the sibling export at live ratification, the documented fix is to set
 * the gateway pseudo-root to /srv/nfs with crossmnt (handbook §3.x).
 *
 * Selective ops: var.enable_backup_repo.
 */

resource "null_resource" "clickhouse_backup_repo" {
  count = var.enable_backup_repo ? 1 : 0

  triggers = {
    schema_id   = length(null_resource.clickhouse_schema_bootstrap) > 0 ? null_resource.clickhouse_schema_bootstrap[0].id : "disabled"
    nfs_server  = var.backup_nfs_server
    nfs_export  = var.backup_nfs_export
    mount_point = var.backup_mount_point
    backup_v    = "1"
    ssh_user    = var.analytics_node_user
  }

  depends_on = [null_resource.clickhouse_schema_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.analytics_node_user}'
      $nfsServer  = '${var.backup_nfs_server}'
      $nfsExport  = '${var.backup_nfs_export}'
      $mountPoint = '${var.backup_mount_point}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $dataNodes = @('192.168.70.44','192.168.70.45','192.168.70.46','192.168.70.47','192.168.70.48','192.168.70.49')

      # Per-node: mount the NFS export (idempotent fstab entry) + register the
      # <backups> Disk in config.d + reload-aware restart of the server.
      $backupsXml = @"
<?xml version="1.0"?>
<clickhouse>
    <storage_configuration>
        <disks>
            <analytics_backups>
                <type>local</type>
                <path>$mountPoint/clickhouse/</path>
            </analytics_backups>
        </disks>
    </storage_configuration>
    <backups>
        <allowed_disk>analytics_backups</allowed_disk>
        <allowed_path>$mountPoint/clickhouse/</allowed_path>
    </backups>
</clickhouse>
"@
      $backupsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($backupsXml -replace "`r`n","`n")))

      foreach ($ip in $dataNodes) {
        Write-Host "[ch-backup-repo $ip] mounting NFS export + registering <backups> disk"
        $setup = @"
set -euo pipefail
sudo mkdir -p '$mountPoint'
# Idempotent fstab entry for the shared NFS backup repository.
FSTAB_LINE='$nfsServer:$nfsExport  $mountPoint  nfs4  vers=4.2,rw,hard,_netdev,timeo=600,retrans=2  0  0'
if ! grep -qF '$mountPoint' /etc/fstab; then
  echo "`$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
fi
if ! mountpoint -q '$mountPoint'; then
  sudo mount '$mountPoint' || sudo mount -t nfs4 -o vers=4.2,rw,hard,_netdev '$nfsServer:$nfsExport' '$mountPoint'
fi
mountpoint -q '$mountPoint' || { echo "ERROR: $mountPoint not mounted" >&2; exit 1; }
sudo mkdir -p '$mountPoint/clickhouse'
sudo chown clickhouse:clickhouse '$mountPoint/clickhouse'

echo '$backupsB64' | base64 -d | sudo tee /etc/clickhouse-server/config.d/nexus-backups.xml > /dev/null
sudo chown root:clickhouse /etc/clickhouse-server/config.d/nexus-backups.xml
sudo chmod 0640 /etc/clickhouse-server/config.d/nexus-backups.xml
sudo systemctl restart nexus-clickhouse-server.service
echo BACKUP_SETUP_OK
"@
        $out = ($setup -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'BACKUP_SETUP_OK') { Write-Host $out.Trim(); throw "[ch-backup-repo $ip] NFS mount / disk registration failed (rc=$LASTEXITCODE)" }
      }

      # Wait for servers to come back after restart.
      foreach ($ip in $dataNodes) {
        $deadline = (Get-Date).AddMinutes(3); $ready = $false
        while ((Get-Date) -lt $deadline) {
          $q = (ssh @sshOpts "$sshUser@$ip" "clickhouse-client --secure --host localhost --port 9440 --query 'SELECT 1' 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($q -eq '1') { $ready = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $ready) { throw "[ch-backup-repo $ip] server not ready after backup-disk restart" }
      }

      # Cross-node BACKUP -> RESTORE round-trip: take on shard1-rep1, restore on
      # shard2-rep1 (proves the repository is genuinely cluster-shared, ADR-0032).
      $take    = '192.168.70.44'
      $restore = '192.168.70.46'
      $bkName  = "ch_smoke_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).zip"
      Write-Host "[ch-backup-repo] BACKUP nexus.events_local on $take -> $bkName"
      $bk = (ssh @sshOpts "$sshUser@$take" "clickhouse-client --secure --host localhost --port 9440 --query `"BACKUP TABLE nexus.events_local TO Disk('analytics_backups', '$bkName')`" 2>&1" 2>&1 | Out-String).Trim()
      if ($bk -notmatch 'BACKUP_CREATED') { Write-Host $bk; throw "[ch-backup-repo] BACKUP did not report BACKUP_CREATED" }

      Write-Host "[ch-backup-repo] RESTORE from $restore (cross-node) into a temp table"
      $rs = (ssh @sshOpts "$sshUser@$restore" "clickhouse-client --secure --host localhost --port 9440 --query `"RESTORE TABLE nexus.events_local AS nexus.events_restore_check FROM Disk('analytics_backups', '$bkName')`" 2>&1" 2>&1 | Out-String).Trim()
      if ($rs -notmatch 'RESTORED') { Write-Host $rs; throw "[ch-backup-repo] cross-node RESTORE did not report RESTORED" }
      $rc = (ssh @sshOpts "$sshUser@$restore" "clickhouse-client --secure --host localhost --port 9440 --query 'SELECT count() FROM nexus.events_restore_check' 2>/dev/null" 2>&1 | Out-String).Trim()
      Write-Host "[ch-backup-repo] restored row count on $restore = $rc"
      # cleanup the restore-check table (best-effort)
      ssh @sshOpts "$sshUser@$restore" "clickhouse-client --secure --host localhost --port 9440 --query 'DROP TABLE IF EXISTS nexus.events_restore_check SYNC'" 2>$null | Out-Null
      if ([int]$rc -le 0) { throw "[ch-backup-repo] cross-node restore produced 0 rows" }
      Write-Host "[ch-backup-repo] cross-node BACKUP/RESTORE round-trip GREEN (shared NFS repository, ADR-0032)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${self.triggers.ssh_user}'
      $mountPoint = '${self.triggers.mount_point}'
      $sshOpts    = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.44','192.168.70.45','192.168.70.46','192.168.70.47','192.168.70.48','192.168.70.49')) {
        Write-Host "[ch-backup-repo destroy] unmounting $mountPoint + removing backup disk config on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/clickhouse-server/config.d/nexus-backups.xml; sudo sed -i '\\#$mountPoint#d' /etc/fstab; sudo umount '$mountPoint' 2>/dev/null || true" 2>$null
      }
      exit 0
    PWSH
  }
}

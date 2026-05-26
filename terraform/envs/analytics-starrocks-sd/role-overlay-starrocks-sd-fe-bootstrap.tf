/*
 * role-overlay-starrocks-sd-fe-bootstrap.tf -- Phase 0.L.5 (ADR-0037)
 *
 * Brings up the StarRocks-shared-data FE quorum (1 leader + 2 followers;
 * BDB-JE majority). Sequence:
 *   1. Append per-host shared-data settings + priority_networks +
 *      cloud_native_meta_port + the right-sized JVM heap to
 *      /opt/starrocks/fe/conf/fe.conf on all 3 FE:
 *        run_mode = shared_data
 *        cloud_native_meta_port = 6090
 *        priority_networks = 192.168.10.0/24
 *        JAVA_OPTS = -Xmx2g -XX:+UseG1GC
 *      (Default ports kept: http 8030, rpc 9020, query 9030, edit_log 9010.)
 *      Storage volume / S3 creds are set via SQL post-bootstrap by
 *      role-overlay-starrocks-sd-storage-volume.tf -- intentionally NOT in
 *      fe.conf (no plaintext S3 secret on disk; volume changeable without
 *      rebaking the FE; supports aws.s3.enable_path_style_access).
 *   2. Start the LEADER first (empty meta -> becomes Leader); wait for
 *      MySQL :9030.
 *   3. For each follower: on the Leader run ALTER SYSTEM ADD FOLLOWER
 *      "<follower_b10>:9010", then first-start the follower with --helper
 *      <leader_b10>:9010 (one-shot join that persists BDB-JE meta), then hand
 *      to systemd.
 *   4. Verify SHOW FRONTENDS = 1 LEADER + 2 FOLLOWER, all Alive.
 *
 * Selective ops: var.enable_sd_fe_bootstrap.
 */

resource "null_resource" "starrocks_sd_fe_bootstrap" {
  count = var.enable_sd_fe_bootstrap ? 1 : 0

  triggers = {
    tls_ids      = join(",", [for h in ["sr-sd-fe-1", "sr-sd-fe-2", "sr-sd-fe-3"] : lookup(local.starrocks_sd_tls_active, h, null) != null ? null_resource.starrocks_sd_tls[h].id : "skip"])
    sd_fe_boot_v = "1"
    ssh_user     = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_sd_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $leaderIp  = '192.168.70.37'; $leaderB10 = '192.168.10.37'
      $followers = @(
        @{ ip='192.168.70.38'; b10='192.168.10.38'; host='sr-sd-fe-2' }
        @{ ip='192.168.70.39'; b10='192.168.10.39'; host='sr-sd-fe-3' }
      )

      # fe.conf per-host append (idempotent: only append once). Sets run_mode=
      # shared_data + cloud_native_meta_port + the VMnet10 priority network +
      # heap. NO S3 creds in fe.conf -- the storage volume is created via SQL
      # post-bootstrap (ADR-0037 section "Storage volume").
      $feConfTmpl = @'
set -euo pipefail
CONF=/opt/starrocks/fe/conf/fe.conf
if ! grep -q '^run_mode' "$CONF"; then
  {
    echo ""
    echo "# --- nexus 0.L.5 shared-data per-host settings ---"
    echo "run_mode = shared_data"
    echo "cloud_native_meta_port = 6090"
    echo "priority_networks = 192.168.10.0/24"
    echo "JAVA_OPTS=\"-Xmx2g -XX:+UseG1GC\""
  } | sudo tee -a "$CONF" > /dev/null
fi
echo FECONF_OK
'@
      foreach ($feip in (@($leaderIp) + @($followers | ForEach-Object { $_.ip }))) {
        $o = ($feConfTmpl -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$feip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'FECONF_OK') { Write-Host $o.Trim(); throw "[sr-sd-fe-bootstrap] fe.conf render failed on $feip" }
      }

      # 1. Start the leader (empty meta -> becomes Leader).
      Write-Host "[sr-sd-fe-bootstrap] starting FE leader ($leaderIp)"
      ssh @sshOpts "$sshUser@$leaderIp" "sudo systemctl daemon-reload; sudo systemctl enable --now nexus-starrocks-sd-fe.service" 2>&1 | Out-String | Write-Host
      $deadline = (Get-Date).AddMinutes($bootTimeout); $ready = $false
      while ((Get-Date) -lt $deadline) {
        $q = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW FRONTENDS' 2>/dev/null | wc -l" 2>&1 | Out-String).Trim()
        if ($q -match '^[1-9]') { $ready = $true; break }
        Start-Sleep -Seconds 8
      }
      if (-not $ready) {
        $jl = (ssh @sshOpts "$sshUser@$leaderIp" "sudo tail -n 40 /opt/starrocks/fe/log/fe.log 2>/dev/null" 2>&1 | Out-String)
        Write-Host $jl; throw "[sr-sd-fe-bootstrap] FE leader not ready on :9030 within $bootTimeout min"
      }
      Write-Host "[sr-sd-fe-bootstrap] FE leader up (shared_data mode)"

      # 2. Join each follower.
      foreach ($f in $followers) {
        Write-Host "[sr-sd-fe-bootstrap] joining follower $($f.host) ($($f.b10))"
        ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -e `"ALTER SYSTEM ADD FOLLOWER '$($f.b10):9010'`"" 2>&1 | Out-String | Write-Host
        $joinTmpl = @'
set -euo pipefail
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
if [ ! -f /opt/starrocks/fe/meta/image/ROLE ] && [ ! -d /opt/starrocks/fe/meta/bdb ]; then
  sudo -u starrocks JAVA_HOME="$JAVA_HOME" /opt/starrocks/fe/bin/start_fe.sh --helper __LEADER_B10__:9010 --daemon
  sleep 15
  sudo -u starrocks JAVA_HOME="$JAVA_HOME" /opt/starrocks/fe/bin/stop_fe.sh || true
  sleep 3
fi
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-starrocks-sd-fe.service
echo JOIN_OK
'@
        $join = $joinTmpl.Replace('__LEADER_B10__', $leaderB10)
        $o = ($join -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($f.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'JOIN_OK') { Write-Host $o.Trim(); throw "[sr-sd-fe-bootstrap] follower $($f.host) join failed" }
        Start-Sleep -Seconds 10
      }

      # 3. Verify quorum: 3 FE alive (1 LEADER + 2 FOLLOWER).
      Write-Host "[sr-sd-fe-bootstrap] verifying FE quorum (1 LEADER + 2 FOLLOWER)"
      $deadline = (Get-Date).AddMinutes(5); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $rows = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW FRONTENDS' 2>/dev/null" 2>&1 | Out-String)
        $aliveTrue = ([regex]::Matches($rows, '(?i)\btrue\b')).Count
        $feCount   = (($rows -split "`n") | Where-Object { $_ -match '\S' }).Count
        Write-Host "[sr-sd-fe-bootstrap]   FE rows=$feCount alive(true)~$aliveTrue"
        if ($feCount -ge 3 -and $aliveTrue -ge 3) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "[sr-sd-fe-bootstrap] FE quorum did not converge to 3 alive FE within 5 min" }
      Write-Host "[sr-sd-fe-bootstrap] FE quorum healthy (3 FE alive in shared_data mode)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.37','192.168.70.38','192.168.70.39')) {
        Write-Host "[sr-sd-fe-bootstrap destroy] stopping FE on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-starrocks-sd-fe.service 2>/dev/null; sudo rm -rf /opt/starrocks/fe/meta/bdb /opt/starrocks/fe/meta/image" 2>$null
      }
      exit 0
    PWSH
  }
}

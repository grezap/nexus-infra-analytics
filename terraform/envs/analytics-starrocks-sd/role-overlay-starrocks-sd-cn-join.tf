/*
 * role-overlay-starrocks-sd-cn-join.tf -- Phase 0.L.5 (ADR-0037)
 *
 * Brings up the 2 StarRocks-shared-data CN (Compute Nodes) + joins them to
 * the FE Leader as COMPUTE NODE (stateless data plane, durable storage in
 * the MinIO storage volume). Sequence:
 *   1. Append per-host priority_networks + storage_root_path to
 *      /opt/starrocks/be/conf/cn.conf on both CN (default ports kept: cn 9060,
 *      heartbeat 9050, brpc 8060, webserver 8040, starlet 9070).
 *   2. Start nexus-starrocks-sd-cn.service on both.
 *   3. On the FE Leader, ALTER SYSTEM ADD COMPUTE NODE "<cn_b10>:9050" for each.
 *   4. Verify SHOW COMPUTE NODES = 2 rows, all Alive=true.
 *
 * Selective ops: var.enable_sd_cn_join.
 */

resource "null_resource" "starrocks_sd_cn_join" {
  count = var.enable_sd_cn_join ? 1 : 0

  triggers = {
    fe_id        = length(null_resource.starrocks_sd_fe_bootstrap) > 0 ? null_resource.starrocks_sd_fe_bootstrap[0].id : "disabled"
    tls_ids      = join(",", [for h in ["sr-sd-cn-1", "sr-sd-cn-2"] : lookup(local.starrocks_sd_tls_active, h, null) != null ? null_resource.starrocks_sd_tls[h].id : "skip"])
    sd_cn_join_v = "1"
    ssh_user     = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_sd_fe_bootstrap, null_resource.starrocks_sd_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $leaderIp    = '192.168.70.37'

      $cns = @(
        @{ ip='192.168.70.30'; b10='192.168.10.30'; host='sr-sd-cn-1' }
        @{ ip='192.168.70.40'; b10='192.168.10.40'; host='sr-sd-cn-2' }
      )

      $cnConfTmpl = @'
set -euo pipefail
CONF=/opt/starrocks/be/conf/cn.conf
if ! grep -q '^priority_networks' "$CONF"; then
  {
    echo ""
    echo "# --- nexus 0.L.5 shared-data per-host CN settings ---"
    echo "priority_networks = 192.168.10.0/24"
    echo "storage_root_path = /opt/starrocks/be/storage"
  } | sudo tee -a "$CONF" > /dev/null
fi
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-starrocks-sd-cn.service
echo CNCONF_OK
'@
      foreach ($cn in $cns) {
        Write-Host "[sr-sd-cn-join] rendering cn.conf + starting CN on $($cn.host)"
        $o = ($cnConfTmpl -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($cn.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'CNCONF_OK') { Write-Host $o.Trim(); throw "[sr-sd-cn-join] cn.conf/start failed on $($cn.host)" }
      }

      # Register each CN on the FE leader (COMPUTE NODE, not BACKEND).
      foreach ($cn in $cns) {
        Write-Host "[sr-sd-cn-join] ALTER SYSTEM ADD COMPUTE NODE $($cn.b10):9050"
        ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -e `"ALTER SYSTEM ADD COMPUTE NODE '$($cn.b10):9050'`" 2>&1 || true" 2>&1 | Out-String | Write-Host
      }

      # Verify 2 CN alive.
      Write-Host "[sr-sd-cn-join] verifying 2 CN alive..."
      $deadline = (Get-Date).AddMinutes($bootTimeout); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $rows = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW COMPUTE NODES' 2>/dev/null" 2>&1 | Out-String)
        $alive   = ([regex]::Matches($rows, '(?i)\btrue\b')).Count
        $cnCount = (($rows -split "`n") | Where-Object { $_ -match '\S' }).Count
        Write-Host "[sr-sd-cn-join]   CN rows=$cnCount alive(true)~$alive"
        if ($cnCount -ge 2 -and $alive -ge 2) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "[sr-sd-cn-join] 2 CN did not become Alive within $bootTimeout min" }
      Write-Host "[sr-sd-cn-join] all 2 CN alive + joined to the FE leader"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.30','192.168.70.40')) {
        Write-Host "[sr-sd-cn-join destroy] stopping CN on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-starrocks-sd-cn.service 2>/dev/null; sudo rm -rf /opt/starrocks/be/storage/*" 2>$null
      }
      exit 0
    PWSH
  }
}

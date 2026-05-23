/*
 * role-overlay-starrocks-be-join.tf -- Phase 0.G.6
 *
 * Brings up the 3 StarRocks BE + joins them to the FE Leader. Sequence:
 *   1. Append per-host priority_networks (VMnet10 backplane) + storage_root_path
 *      to /opt/starrocks/be/conf/be.conf on all 3 BE (default ports kept:
 *      be 9060, heartbeat 9050, brpc 8060, webserver 8040).
 *   2. Start nexus-starrocks-be.service on all 3.
 *   3. On the FE Leader, ALTER SYSTEM ADD BACKEND "<be_b10>:9050" for each.
 *   4. Verify SHOW BACKENDS = 3 rows, all Alive=true.
 *
 * Selective ops: var.enable_be_join.
 */

resource "null_resource" "starrocks_be_join" {
  count = var.enable_be_join ? 1 : 0

  triggers = {
    fe_id     = length(null_resource.starrocks_fe_bootstrap) > 0 ? null_resource.starrocks_fe_bootstrap[0].id : "disabled"
    tls_ids   = join(",", [for h in ["sr-be-1", "sr-be-2", "sr-be-3"] : lookup(local.starrocks_tls_active, h, null) != null ? null_resource.starrocks_tls[h].id : "skip"])
    be_join_v = "1"
    ssh_user  = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_fe_bootstrap, null_resource.starrocks_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $leaderIp    = '192.168.70.31'

      $bes = @(
        @{ ip='192.168.70.34'; b10='192.168.10.34'; host='sr-be-1' }
        @{ ip='192.168.70.35'; b10='192.168.10.35'; host='sr-be-2' }
        @{ ip='192.168.70.36'; b10='192.168.10.36'; host='sr-be-3' }
      )

      $beConfTmpl = @'
set -euo pipefail
CONF=/opt/starrocks/be/conf/be.conf
if ! grep -q '^priority_networks' "$CONF"; then
  {
    echo ""
    echo "# --- nexus 0.G.6 per-host settings ---"
    echo "priority_networks = 192.168.10.0/24"
    echo "storage_root_path = /opt/starrocks/be/storage"
  } | sudo tee -a "$CONF" > /dev/null
fi
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-starrocks-be.service
echo BECONF_OK
'@
      foreach ($be in $bes) {
        Write-Host "[sr-be-join] rendering be.conf + starting BE on $($be.host)"
        $o = ($beConfTmpl -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($be.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'BECONF_OK') { Write-Host $o.Trim(); throw "[sr-be-join] be.conf/start failed on $($be.host)" }
      }

      # Register each BE on the FE leader.
      foreach ($be in $bes) {
        Write-Host "[sr-be-join] ALTER SYSTEM ADD BACKEND $($be.b10):9050"
        ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -e `"ALTER SYSTEM ADD BACKEND '$($be.b10):9050'`" 2>&1 || true" 2>&1 | Out-String | Write-Host
      }

      # Verify 3 BE alive.
      Write-Host "[sr-be-join] verifying 3 BE alive..."
      $deadline = (Get-Date).AddMinutes($bootTimeout); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $rows = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW BACKENDS' 2>/dev/null" 2>&1 | Out-String)
        $alive = ([regex]::Matches($rows, '(?i)\btrue\b')).Count
        $beCount = (($rows -split "`n") | Where-Object { $_ -match '\S' }).Count
        Write-Host "[sr-be-join]   BE rows=$beCount alive(true)~$alive"
        if ($beCount -ge 3 -and $alive -ge 3) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "[sr-be-join] 3 BE did not become Alive within $bootTimeout min" }
      Write-Host "[sr-be-join] all 3 BE alive + joined to the FE leader"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.34','192.168.70.35','192.168.70.36')) {
        Write-Host "[sr-be-join destroy] stopping BE on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-starrocks-be.service 2>/dev/null; sudo rm -rf /opt/starrocks/be/storage/*" 2>$null
      }
      exit 0
    PWSH
  }
}

/*
 * role-overlay-starrocks-fe-bootstrap.tf -- Phase 0.G.6
 *
 * Brings up the StarRocks FE quorum (1 leader + 2 followers; BDB-JE majority).
 * Per ADR-0030. Sequence:
 *   1. Append per-host priority_networks (the VMnet10 backplane) + the right-sized
 *      JVM heap to /opt/starrocks/fe/conf/fe.conf on all 3 FE (default ports kept:
 *      http 8030, rpc 9020, query 9030, edit_log 9010).
 *   2. Start the LEADER first (empty meta -> becomes Leader); wait for MySQL :9030.
 *   3. For each follower: on the Leader run ALTER SYSTEM ADD FOLLOWER
 *      "<follower_b10>:9010", then first-start the follower with --helper
 *      <leader_b10>:9010 (one-shot join that persists BDB-JE meta), then hand it
 *      to systemd (subsequent restarts read the persisted meta, no --helper).
 *   4. Verify SHOW FRONTENDS = 1 LEADER + 2 FOLLOWER, all Alive.
 *
 * StarRocks-specific + ratification-sensitive: the exact --helper one-shot ->
 * systemd handover + the heap sizing are confirmed at live ratification and
 * any deltas chronicled in handbook §3.x.
 *
 * Selective ops: var.enable_fe_bootstrap.
 */

resource "null_resource" "starrocks_fe_bootstrap" {
  count = var.enable_fe_bootstrap ? 1 : 0

  triggers = {
    tls_ids   = join(",", [for h in ["sr-fe-leader", "sr-fe-follower-1", "sr-fe-follower-2"] : lookup(local.starrocks_tls_active, h, null) != null ? null_resource.starrocks_tls[h].id : "skip"])
    fe_boot_v = "1"
    ssh_user  = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $leaderIp  = '192.168.70.31'; $leaderB10 = '192.168.10.31'
      $followers = @(
        @{ ip='192.168.70.32'; b10='192.168.10.32'; host='sr-fe-follower-1' }
        @{ ip='192.168.70.33'; b10='192.168.10.33'; host='sr-fe-follower-2' }
      )

      # fe.conf per-host append (idempotent: only append once). priority_networks
      # binds the FE to the VMnet10 backplane; heap right-sized to the 4 GB node.
      $feConfTmpl = @'
set -euo pipefail
CONF=/opt/starrocks/fe/conf/fe.conf
if ! grep -q '^priority_networks' "$CONF"; then
  {
    echo ""
    echo "# --- nexus 0.G.6 per-host settings ---"
    echo "priority_networks = 192.168.10.0/24"
    echo "JAVA_OPTS=\"-Xmx2g -XX:+UseG1GC\""
  } | sudo tee -a "$CONF" > /dev/null
fi
echo FECONF_OK
'@
      # NB: @($a, ($pipe)) does NOT flatten the inner array in PowerShell -- the
      # 2nd element becomes the whole follower-IP array, so `ssh user@<array>`
      # gets a space-joined host. Use `+` concatenation, which flattens.
      foreach ($feip in (@($leaderIp) + @($followers | ForEach-Object { $_.ip }))) {
        $o = ($feConfTmpl -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$feip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'FECONF_OK') { Write-Host $o.Trim(); throw "[sr-fe-bootstrap] fe.conf render failed on $feip" }
      }

      # 1. Start the leader (empty meta -> becomes Leader).
      Write-Host "[sr-fe-bootstrap] starting FE leader ($leaderIp)"
      ssh @sshOpts "$sshUser@$leaderIp" "sudo systemctl daemon-reload; sudo systemctl enable --now nexus-starrocks-fe.service" 2>&1 | Out-String | Write-Host
      $deadline = (Get-Date).AddMinutes($bootTimeout); $ready = $false
      while ((Get-Date) -lt $deadline) {
        $q = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW FRONTENDS' 2>/dev/null | wc -l" 2>&1 | Out-String).Trim()
        if ($q -match '^[1-9]') { $ready = $true; break }
        Start-Sleep -Seconds 8
      }
      if (-not $ready) {
        $jl = (ssh @sshOpts "$sshUser@$leaderIp" "sudo tail -n 40 /opt/starrocks/fe/log/fe.log 2>/dev/null" 2>&1 | Out-String)
        Write-Host $jl; throw "[sr-fe-bootstrap] FE leader not ready on :9030 within $bootTimeout min"
      }
      Write-Host "[sr-fe-bootstrap] FE leader up"

      # 2. Join each follower.
      foreach ($f in $followers) {
        Write-Host "[sr-fe-bootstrap] joining follower $($f.host) ($($f.b10))"
        # 2a. Register on the leader.
        ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -e `"ALTER SYSTEM ADD FOLLOWER '$($f.b10):9010'`"" 2>&1 | Out-String | Write-Host
        # 2b. First-start with --helper (one-shot join; persists BDB-JE meta), then systemd handover.
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
sudo systemctl enable --now nexus-starrocks-fe.service
echo JOIN_OK
'@
        $join = $joinTmpl.Replace('__LEADER_B10__', $leaderB10)
        $o = ($join -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($f.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'JOIN_OK') { Write-Host $o.Trim(); throw "[sr-fe-bootstrap] follower $($f.host) join failed" }
        Start-Sleep -Seconds 10
      }

      # 3. Verify quorum: 1 LEADER + 2 FOLLOWER, all Alive.
      Write-Host "[sr-fe-bootstrap] verifying FE quorum (1 LEADER + 2 FOLLOWER)"
      $deadline = (Get-Date).AddMinutes(5); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $rows = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SHOW FRONTENDS' 2>/dev/null" 2>&1 | Out-String)
        $leaders   = ([regex]::Matches($rows, '(?i)\btrue\b.*\bLEADER\b')).Count + ([regex]::Matches($rows, '(?im)LEADER.*\btrue\b')).Count
        $aliveTrue = ([regex]::Matches($rows, '(?i)\btrue\b')).Count
        $feCount   = (($rows -split "`n") | Where-Object { $_ -match '\S' }).Count
        Write-Host "[sr-fe-bootstrap]   FE rows=$feCount alive(true)~$aliveTrue"
        if ($feCount -ge 3 -and $aliveTrue -ge 3) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "[sr-fe-bootstrap] FE quorum did not converge to 3 alive FE within 5 min" }
      Write-Host "[sr-fe-bootstrap] FE quorum healthy (3 FE alive: 1 leader + 2 followers)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.31','192.168.70.32','192.168.70.33')) {
        Write-Host "[sr-fe-bootstrap destroy] stopping FE on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-starrocks-fe.service 2>/dev/null; sudo rm -rf /opt/starrocks/fe/meta/bdb /opt/starrocks/fe/meta/image" 2>$null
      }
      exit 0
    PWSH
  }
}

/*
 * role-overlay-clickhouse-keeper-config.tf -- Phase 0.G.5
 *
 * Renders keeper_config.xml on the 3 Keeper nodes (per-host server_id 1/2/3 +
 * the shared 3-server raft_configuration on the VMnet10 backplane), enables +
 * starts nexus-clickhouse-keeper.service on all three, and waits for the RAFT
 * quorum to converge (exactly one leader via the `mntr` 4-letter-word).
 *
 * mTLS posture (ADR-0028/0029):
 *   - RAFT inter-keeper traffic (9234) is TLS (<secure>true</secure> per server
 *     + <openSSL> pointing at the rendered /etc/nexus-clickhouse-keeper/tls).
 *   - <tcp_port_secure> 9281 is the mTLS client port the clickhouse-server
 *     nodes connect to (server-config overlay sets <zookeeper><secure>1</secure>).
 *   - <tcp_port> 9181 is bound for the read-only 4-letter-word health interface
 *     (mntr/ruok/stat) on the trusted segment -- diagnostics only, not a data path.
 *
 * One-shot (count=1): renders all 3, parallel start, quorum wait. Depends on the
 * TLS overlay (certs must exist before Keeper starts with TLS enabled).
 *
 * Selective ops: var.enable_keeper_config.
 */

locals {
  # server_id (1..3) + VMnet10 backplane IP for each keeper. raft_configuration
  # uses the backplane IPs (9234); listen + client on both NICs.
  clickhouse_keepers = {
    "ch-keeper-1" = { id = 1, vmnet10 = "192.168.10.41", vmnet11 = "192.168.70.41" }
    "ch-keeper-2" = { id = 2, vmnet10 = "192.168.10.42", vmnet11 = "192.168.70.42" }
    "ch-keeper-3" = { id = 3, vmnet10 = "192.168.10.43", vmnet11 = "192.168.70.43" }
  }
}

resource "null_resource" "clickhouse_keeper_config" {
  count = var.enable_keeper_config ? 1 : 0

  triggers = {
    tls_ids      = join(",", [for h in ["ch-keeper-1", "ch-keeper-2", "ch-keeper-3"] : lookup(local.clickhouse_tls_active, h, null) != null ? null_resource.clickhouse_tls[h].id : "skip"])
    raft_port    = var.clickhouse_keeper_raft_port
    client_port  = var.clickhouse_keeper_client_port
    keeper_cfg_v = "1"
    ssh_user     = var.analytics_node_user
  }

  depends_on = [null_resource.clickhouse_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $clientPort  = ${var.clickhouse_keeper_client_port}
      $raftPort    = ${var.clickhouse_keeper_raft_port}
      $securePort  = 9281
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $keepers = @(
        @{ host='ch-keeper-1'; id=1; vmnet10='192.168.10.41'; vmnet11='192.168.70.41' }
        @{ host='ch-keeper-2'; id=2; vmnet10='192.168.10.42'; vmnet11='192.168.70.42' }
        @{ host='ch-keeper-3'; id=3; vmnet10='192.168.10.43'; vmnet11='192.168.70.43' }
      )

      # Shared raft_configuration (all 3 servers; backplane IPs; TLS).
      $raftServers = ($keepers | ForEach-Object {
        "        <server><id>$($_.id)</id><hostname>$($_.vmnet10)</hostname><port>$raftPort</port><secure>true</secure></server>"
      }) -join "`n"

      foreach ($k in $keepers) {
        $h  = $k.host; $id = $k.id; $b10 = $k.vmnet10; $ip = $k.vmnet11
        Write-Host "[ch-keeper-config $h] rendering keeper_config.xml (server_id=$id)"

        $cfg = @"
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/nexus-clickhouse-keeper/clickhouse-keeper.log</log>
        <errorlog>/var/log/nexus-clickhouse-keeper/clickhouse-keeper.err.log</errorlog>
        <size>100M</size>
        <count>5</count>
    </logger>
    <listen_host>::</listen_host>
    <max_connections>4096</max_connections>

    <keeper_server>
        <tcp_port>$clientPort</tcp_port>
        <tcp_port_secure>$securePort</tcp_port_secure>
        <server_id>$id</server_id>
        <log_storage_path>/var/lib/nexus-clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/nexus-clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
        </coordination_settings>

        <raft_configuration>
$raftServers
        </raft_configuration>
    </keeper_server>

    <openSSL>
        <server>
            <certificateFile>/etc/nexus-clickhouse-keeper/tls/server.crt</certificateFile>
            <privateKeyFile>/etc/nexus-clickhouse-keeper/tls/server.key</privateKeyFile>
            <caConfig>/etc/nexus-clickhouse-keeper/tls/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <disableProtocols>sslv2,sslv3</disableProtocols>
            <preferServerCiphers>true</preferServerCiphers>
        </server>
        <client>
            <certificateFile>/etc/nexus-clickhouse-keeper/tls/server.crt</certificateFile>
            <privateKeyFile>/etc/nexus-clickhouse-keeper/tls/server.key</privateKeyFile>
            <caConfig>/etc/nexus-clickhouse-keeper/tls/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
        </client>
    </openSSL>

    <!-- four-letter-word health interface (read-only) for the smoke gate -->
    <four_letter_word_white_list>conf,cons,crst,envi,ruok,srst,srvr,stat,wchs,dirs,mntr,isro,rcvr,apiv,csnp,lgif,rqld,ydld</four_letter_word_white_list>
</clickhouse>
"@
        $cfgB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cfg -replace "`r`n","`n")))

        $render = @"
set -euo pipefail
sudo mkdir -p /var/lib/nexus-clickhouse-keeper/coordination/log /var/lib/nexus-clickhouse-keeper/coordination/snapshots
sudo chown -R clickhouse:clickhouse /var/lib/nexus-clickhouse-keeper
echo '$cfgB64' | base64 -d | sudo tee /etc/nexus-clickhouse-keeper/keeper_config.xml > /dev/null
sudo chown root:clickhouse /etc/nexus-clickhouse-keeper/keeper_config.xml
sudo chmod 0640 /etc/nexus-clickhouse-keeper/keeper_config.xml
echo RENDER_OK
"@
        $out = ($render -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'RENDER_OK') { Write-Host $out.Trim(); throw "[ch-keeper-config $h] render failed (rc=$LASTEXITCODE)" }
      }

      # Parallel start (RAFT quorum needs peers up roughly together).
      Write-Host "[ch-keeper-config] enabling + starting nexus-clickhouse-keeper on all 3 keepers (parallel)"
      foreach ($k in $keepers) {
        $ip = $k.vmnet11
        Start-Job -ScriptBlock {
          param($ip,$sshUser)
          $o = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
          ssh @o "$sshUser@$ip" "sudo systemctl daemon-reload; sudo systemctl enable --now nexus-clickhouse-keeper.service" 2>&1
        } -ArgumentList $ip,$sshUser | Out-Null
      }
      Get-Job | Wait-Job -Timeout 120 | Out-Null
      Get-Job | Receive-Job | ForEach-Object { Write-Host $_ }
      Get-Job | Remove-Job -Force

      # Wait for quorum: exactly one leader across the 3 via `mntr`.
      Write-Host "[ch-keeper-config] waiting for RAFT quorum (1 leader + 2 followers)..."
      $deadline = (Get-Date).AddMinutes($bootTimeout)
      $converged = $false
      while ((Get-Date) -lt $deadline) {
        $states = @()
        foreach ($k in $keepers) {
          $st = (ssh @sshOpts "$sshUser@$($k.vmnet11)" "exec 3<>/dev/tcp/127.0.0.1/$clientPort; printf 'mntr\n' >&3; timeout 3 cat <&3 2>/dev/null | grep zk_server_state | awk '{print `$2}'" 2>&1 | Out-String).Trim()
          if ($st) { $states += $st }
        }
        $leaders   = ($states | Where-Object { $_ -eq 'leader' }).Count
        $followers = ($states | Where-Object { $_ -eq 'follower' }).Count
        Write-Host "[ch-keeper-config]   states: $($states -join ',')  (leaders=$leaders followers=$followers)"
        if ($leaders -eq 1 -and $followers -eq 2) { $converged = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $converged) { throw "[ch-keeper-config] RAFT quorum did not converge to 1 leader + 2 followers within $bootTimeout min" }
      Write-Host "[ch-keeper-config] RAFT quorum healthy: 1 leader + 2 followers"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.41','192.168.70.42','192.168.70.43')) {
        Write-Host "[ch-keeper-config destroy] stopping nexus-clickhouse-keeper on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-clickhouse-keeper.service 2>/dev/null; sudo rm -f /etc/nexus-clickhouse-keeper/keeper_config.xml; sudo rm -rf /var/lib/nexus-clickhouse-keeper/coordination" 2>$null
      }
      exit 0
    PWSH
  }
}

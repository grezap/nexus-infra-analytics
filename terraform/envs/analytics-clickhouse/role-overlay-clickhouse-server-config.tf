/*
 * role-overlay-clickhouse-server-config.tf -- Phase 0.G.5
 *
 * Renders the cluster-specific ClickHouse config onto the 6 data nodes as
 * config.d/ + users.d/ deltas over the package base (ClickHouse merges natively),
 * then enables + starts nexus-clickhouse-server.service on all 6.
 *
 * config.d/nexus-cluster.xml carries:
 *   - remote_servers/nexus_analytics: 3 shards x 2 replicas, internal_replication
 *     =true, replica host = VMnet10 backplane IP, secure native port 9440 (ADR-0029)
 *   - per-node <macros> {shard}/{replica} (derived from hostname ch-shardN-repM)
 *     so one CREATE TABLE ... ON CLUSTER self-identifies each node
 *   - <zookeeper>: the 3 Keeper nodes on the secure client port 9281 (<secure>1)
 *   - secure-only listeners: https_port 8443, tcp_port_secure 9440,
 *     interserver_https_port 9010; plain 8123/9000/9009 removed
 *   - <openSSL> server + client pointing at /etc/clickhouse-server/tls
 *
 * users.d/nexus-bootstrap.xml restricts the `default` user to localhost +
 * grants access_management so role-overlay-clickhouse-schema-bootstrap.tf can
 * run SQL-driven RBAC (CREATE USER/ROLE/GRANT) as default@localhost on-node.
 *
 * One-shot (count=1): render all 6 + parallel start + per-node readiness wait.
 * The ON CLUSTER schema/RBAC bring-up is the next overlay (schema-bootstrap).
 *
 * Selective ops: var.enable_server_config.
 */

locals {
  # data node -> shard/replica + backplane/service IPs.
  clickhouse_data_nodes = {
    "ch-shard1-rep1" = { shard = 1, replica = 1, vmnet10 = "192.168.10.44", vmnet11 = "192.168.70.44" }
    "ch-shard1-rep2" = { shard = 1, replica = 2, vmnet10 = "192.168.10.45", vmnet11 = "192.168.70.45" }
    "ch-shard2-rep1" = { shard = 2, replica = 1, vmnet10 = "192.168.10.46", vmnet11 = "192.168.70.46" }
    "ch-shard2-rep2" = { shard = 2, replica = 2, vmnet10 = "192.168.10.47", vmnet11 = "192.168.70.47" }
    "ch-shard3-rep1" = { shard = 3, replica = 1, vmnet10 = "192.168.10.48", vmnet11 = "192.168.70.48" }
    "ch-shard3-rep2" = { shard = 3, replica = 2, vmnet10 = "192.168.10.49", vmnet11 = "192.168.70.49" }
  }
}

resource "null_resource" "clickhouse_server_config" {
  count = var.enable_server_config ? 1 : 0

  triggers = {
    keeper_id    = length(null_resource.clickhouse_keeper_config) > 0 ? null_resource.clickhouse_keeper_config[0].id : "disabled"
    tls_ids      = join(",", [for h in keys(local.clickhouse_data_nodes) : lookup(local.clickhouse_tls_active, h, null) != null ? null_resource.clickhouse_tls[h].id : "skip"])
    cluster_name = var.clickhouse_cluster_name
    server_cfg_v = "1"
    ssh_user     = var.analytics_node_user
  }

  depends_on = [null_resource.clickhouse_keeper_config, null_resource.clickhouse_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.analytics_node_user}'
      $clusterName = '${var.clickhouse_cluster_name}'
      $securePort  = 9281   # Keeper secure client port
      $nativeTls   = 9440   # ClickHouse native TLS (inter-replica + clients)
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $dataNodes = @(
        @{ host='ch-shard1-rep1'; shard=1; replica=1; b10='192.168.10.44'; ip='192.168.70.44' }
        @{ host='ch-shard1-rep2'; shard=1; replica=2; b10='192.168.10.45'; ip='192.168.70.45' }
        @{ host='ch-shard2-rep1'; shard=2; replica=1; b10='192.168.10.46'; ip='192.168.70.46' }
        @{ host='ch-shard2-rep2'; shard=2; replica=2; b10='192.168.10.47'; ip='192.168.70.47' }
        @{ host='ch-shard3-rep1'; shard=3; replica=1; b10='192.168.10.48'; ip='192.168.70.48' }
        @{ host='ch-shard3-rep2'; shard=3; replica=2; b10='192.168.10.49'; ip='192.168.70.49' }
      )
      $keepers = @('192.168.10.41','192.168.10.42','192.168.10.43')

      # Shared remote_servers cluster (3 shards x 2 replicas; backplane; secure 9440).
      $shardXml = ""
      foreach ($s in 1,2,3) {
        $reps = $dataNodes | Where-Object { $_.shard -eq $s } | Sort-Object replica
        $repXml = ($reps | ForEach-Object {
          "                <replica><host>$($_.b10)</host><port>$nativeTls</port><secure>1</secure></replica>"
        }) -join "`n"
        $shardXml += "            <shard>`n                <internal_replication>true</internal_replication>`n$repXml`n            </shard>`n"
      }
      $zkXml = ($keepers | ForEach-Object {
        "            <node><host>$_</host><port>$securePort</port><secure>1</secure></node>"
      }) -join "`n"

      # Bootstrap users.d -- default user localhost-only + access_management so
      # schema-bootstrap can run SQL RBAC as default@localhost.
      $usersXml = @"
<?xml version="1.0"?>
<clickhouse>
    <users>
        <default>
            <networks replace="replace">
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </default>
    </users>
</clickhouse>
"@
      $usersB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($usersXml -replace "`r`n","`n")))

      foreach ($n in $dataNodes) {
        $h = $n.host; $shard = $n.shard; $replica = $n.replica; $b10 = $n.b10; $ip = $n.ip
        Write-Host "[ch-server-config $h] rendering config.d/nexus-cluster.xml (shard=$shard replica=$replica)"

        $cfg = @"
<?xml version="1.0"?>
<clickhouse>
    <listen_host>::</listen_host>

    <!-- secure-only listeners; plain ports removed (ADR-0029 mTLS-only) -->
    <https_port>8443</https_port>
    <tcp_port_secure>9440</tcp_port_secure>
    <tcp_port remove="1"/>
    <http_port remove="1"/>
    <mysql_port remove="1"/>
    <interserver_http_port remove="1"/>
    <interserver_https_port>9010</interserver_https_port>
    <interserver_http_host>$b10</interserver_http_host>

    <macros>
        <shard>$shard</shard>
        <replica>$h</replica>
        <cluster>$clusterName</cluster>
    </macros>

    <remote_servers replace="replace">
        <$clusterName>
            <secret>nexus_analytics_internal</secret>
$shardXml        </$clusterName>
    </remote_servers>

    <zookeeper replace="replace">
$zkXml
    </zookeeper>

    <distributed_ddl>
        <path>/clickhouse/task_queue/ddl</path>
    </distributed_ddl>

    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/tls/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/tls/server.key</privateKeyFile>
            <caConfig>/etc/clickhouse-server/tls/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <disableProtocols>sslv2,sslv3</disableProtocols>
            <preferServerCiphers>true</preferServerCiphers>
        </server>
        <client>
            <certificateFile>/etc/clickhouse-server/tls/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/tls/server.key</privateKeyFile>
            <caConfig>/etc/clickhouse-server/tls/ca.crt</caConfig>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <verificationMode>relaxed</verificationMode>
            <invalidCertificateHandler><name>RejectCertificateHandler</name></invalidCertificateHandler>
        </client>
    </openSSL>
</clickhouse>
"@
        $cfgB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cfg -replace "`r`n","`n")))

        $render = @"
set -euo pipefail
echo '$cfgB64' | base64 -d | sudo tee /etc/clickhouse-server/config.d/nexus-cluster.xml > /dev/null
sudo chown root:clickhouse /etc/clickhouse-server/config.d/nexus-cluster.xml
sudo chmod 0640 /etc/clickhouse-server/config.d/nexus-cluster.xml
echo '$usersB64' | base64 -d | sudo tee /etc/clickhouse-server/users.d/nexus-bootstrap.xml > /dev/null
sudo chown root:clickhouse /etc/clickhouse-server/users.d/nexus-bootstrap.xml
sudo chmod 0640 /etc/clickhouse-server/users.d/nexus-bootstrap.xml
echo RENDER_OK
"@
        $out = ($render -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'RENDER_OK') { Write-Host $out.Trim(); throw "[ch-server-config $h] render failed (rc=$LASTEXITCODE)" }
      }

      # Parallel start.
      Write-Host "[ch-server-config] enabling + starting nexus-clickhouse-server on all 6 data nodes (parallel)"
      foreach ($n in $dataNodes) {
        Start-Job -ScriptBlock {
          param($ip,$sshUser)
          $o = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
          ssh @o "$sshUser@$ip" "sudo systemctl daemon-reload; sudo systemctl enable --now nexus-clickhouse-server.service" 2>&1
        } -ArgumentList $n.ip,$sshUser | Out-Null
      }
      Get-Job | Wait-Job -Timeout 180 | Out-Null
      Get-Job | Receive-Job | ForEach-Object { Write-Host $_ }
      Get-Job | Remove-Job -Force

      # Per-node readiness: clickhouse-client (secure, on-node) answers SELECT 1.
      foreach ($n in $dataNodes) {
        $h = $n.host; $ip = $n.ip
        Write-Host "[ch-server-config $h] waiting for server readiness (SELECT 1)..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $q = (ssh @sshOpts "$sshUser@$ip" "clickhouse-client --secure --host localhost --port 9440 --query 'SELECT 1' 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($q -eq '1') { $ready = $true; break }
          Start-Sleep -Seconds 8
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-clickhouse-server.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[ch-server-config $h] server not ready (SELECT 1) within $bootTimeout min"
        }
        Write-Host "[ch-server-config $h] server ready"
      }
      Write-Host "[ch-server-config] all 6 data nodes ready on mTLS"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.44','192.168.70.45','192.168.70.46','192.168.70.47','192.168.70.48','192.168.70.49')) {
        Write-Host "[ch-server-config destroy] stopping nexus-clickhouse-server on $ip"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-clickhouse-server.service 2>/dev/null; sudo rm -f /etc/clickhouse-server/config.d/nexus-cluster.xml /etc/clickhouse-server/users.d/nexus-bootstrap.xml" 2>$null
      }
      exit 0
    PWSH
  }
}

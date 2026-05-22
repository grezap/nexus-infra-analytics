/*
 * role-overlay-clickhouse-nftables-backplane.tf -- Phase 0.G.5
 *
 * Pushes the per-cluster nftables ruleset to all 9 ClickHouse nodes (3 Keeper
 * + 6 data) + `nft -f` at apply time. The canonical source of truth (the baked
 * baseline in each Packer template's files/nftables.conf is the cold-clone
 * safety net only).
 *
 * Single ruleset for all 9 nodes (keeper + server): trust the VMnet10 backplane
 * (Keeper RAFT 9234 + client 9181, inter-server replication 9010, native 9440)
 * + open the operator/smoke ports on VMnet11 (9181 keeper-client, 8443 HTTPS,
 * 9440 native-TLS). Opening a port a given node doesn't listen on is harmless.
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md: the
 * `iifname "nic1" ip saddr 192.168.10.0/24 accept` rule is what makes the
 * cluster backplane work; without it ping passes but TCP does not. Per
 * memory/feedback_nftables_runtime_add_after_drop.md the whole ruleset is
 * replaced atomically via `nft -f` (NOT runtime `nft add rule`, which lands
 * after the canonical drop).
 *
 * Selective ops: var.enable_nftables_backplane (default true).
 */

locals {
  clickhouse_all_nodes = {
    "ch-keeper-1"    = "192.168.70.41"
    "ch-keeper-2"    = "192.168.70.42"
    "ch-keeper-3"    = "192.168.70.43"
    "ch-shard1-rep1" = "192.168.70.44"
    "ch-shard1-rep2" = "192.168.70.45"
    "ch-shard2-rep1" = "192.168.70.46"
    "ch-shard2-rep2" = "192.168.70.47"
    "ch-shard3-rep1" = "192.168.70.48"
    "ch-shard3-rep2" = "192.168.70.49"
  }
}

resource "null_resource" "clickhouse_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    node_ips      = join(",", values(local.clickhouse_all_nodes))
    nftables_v    = "1"
    ssh_user      = var.analytics_node_user
    boot_timeout  = var.analytics_cluster_timeout_minutes
    destroy_nodes = join(",", values(local.clickhouse_all_nodes))
    destroy_user  = var.analytics_node_user
  }

  depends_on = [
    module.ch_keeper_1, module.ch_keeper_2, module.ch_keeper_3,
    module.ch_shard1_rep1, module.ch_shard1_rep2,
    module.ch_shard2_rep1, module.ch_shard2_rep2,
    module.ch_shard3_rep1, module.ch_shard3_rep2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.clickhouse_all_nodes : "'${h}' = '${ip}'"])} }
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # The canonical ruleset (literal here-string; no interpolation needed).
      $ruleset = @'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state { established, related } accept
        ct state invalid drop
        ip protocol icmp   accept
        ip6 nexthdr icmpv6 accept
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 22   accept comment "SSH from VMnet11"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 9100 accept comment "node_exporter from VMnet11"
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted cluster backplane (VMnet10)"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 9181, 8443, 9440 } accept comment "ClickHouse Keeper-client + HTTPS + native-TLS from VMnet11"
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
'@
      $rulesetB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($ruleset -replace "`r`n","`n")))

      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key
        $ip       = $entry.Value
        Write-Host "[ch-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/analytics-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[ch-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') {
          Write-Host $out.Trim()
          throw "[ch-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)"
        }
        Write-Host "[ch-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}

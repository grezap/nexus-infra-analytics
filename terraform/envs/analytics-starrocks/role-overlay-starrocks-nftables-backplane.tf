/*
 * role-overlay-starrocks-nftables-backplane.tf -- Phase 0.G.6
 *
 * Pushes the per-cluster nftables ruleset to all 6 StarRocks nodes (3 FE + 3 BE)
 * + `nft -f`. Single ruleset for all 6: trust the VMnet10 backplane (FE edit_log
 * 9010 + rpc 9020 + FE<->BE thrift/heartbeat/brpc 9060/9050/8060) + open the
 * client/operator ports on VMnet11 (FE MySQL 9030 + HTTP 8030 + BE webserver 8040).
 * Opening a port a node doesn't listen on is harmless.
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md + feedback_nftables_
 * runtime_add_after_drop.md (atomic `nft -f`, not runtime add).
 */

locals {
  starrocks_all_nodes = {
    "sr-fe-leader"     = "192.168.70.31"
    "sr-fe-follower-1" = "192.168.70.32"
    "sr-fe-follower-2" = "192.168.70.33"
    "sr-be-1"          = "192.168.70.34"
    "sr-be-2"          = "192.168.70.35"
    "sr-be-3"          = "192.168.70.36"
  }
}

resource "null_resource" "starrocks_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.starrocks_all_nodes))
    nftables_v   = "1"
    ssh_user     = var.analytics_node_user
    boot_timeout = var.analytics_cluster_timeout_minutes
  }

  depends_on = [
    module.sr_fe_leader, module.sr_fe_follower_1, module.sr_fe_follower_2,
    module.sr_be_1, module.sr_be_2, module.sr_be_3,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.starrocks_all_nodes : "'${h}' = '${ip}'"])} }
      $sshUser     = '${var.analytics_node_user}'
      $bootTimeout = ${var.analytics_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

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
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 9030, 8030, 8040 } accept comment "StarRocks FE MySQL/HTTP + BE webserver from VMnet11"
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
        Write-Host "[sr-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/analytics-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[sr-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[sr-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
        Write-Host "[sr-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}

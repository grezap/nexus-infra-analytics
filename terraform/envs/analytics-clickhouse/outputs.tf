# nexus-infra-analytics / terraform / envs / analytics-clickhouse / outputs.tf

output "clickhouse_topology" {
  description = "ClickHouse cluster topology: 3-node Keeper quorum + 3 shards x 2 replicas. Reach data nodes via round-robin DNS clickhouse.nexus.lab (HTTPS 8443, native-TLS 9440) or the per-node VMnet11 IPs."
  value = {
    cluster_name = var.clickhouse_cluster_name
    front_door   = "clickhouse.nexus.lab (round-robin over the 6 data nodes; no VIP -- ADR-0031)"
    keeper = {
      for n in ["ch-keeper-1", "ch-keeper-2", "ch-keeper-3"] : n => {
        service_ip   = lookup({ "ch-keeper-1" = "192.168.70.41", "ch-keeper-2" = "192.168.70.42", "ch-keeper-3" = "192.168.70.43" }, n)
        backplane_ip = lookup({ "ch-keeper-1" = "192.168.10.41", "ch-keeper-2" = "192.168.10.42", "ch-keeper-3" = "192.168.10.43" }, n)
        client_port  = var.clickhouse_keeper_client_port
        raft_port    = var.clickhouse_keeper_raft_port
      }
    }
    data = {
      for n in ["ch-shard1-rep1", "ch-shard1-rep2", "ch-shard2-rep1", "ch-shard2-rep2", "ch-shard3-rep1", "ch-shard3-rep2"] : n => {
        service_ip   = lookup({ "ch-shard1-rep1" = "192.168.70.44", "ch-shard1-rep2" = "192.168.70.45", "ch-shard2-rep1" = "192.168.70.46", "ch-shard2-rep2" = "192.168.70.47", "ch-shard3-rep1" = "192.168.70.48", "ch-shard3-rep2" = "192.168.70.49" }, n)
        backplane_ip = lookup({ "ch-shard1-rep1" = "192.168.10.44", "ch-shard1-rep2" = "192.168.10.45", "ch-shard2-rep1" = "192.168.10.46", "ch-shard2-rep2" = "192.168.10.47", "ch-shard3-rep1" = "192.168.10.48", "ch-shard3-rep2" = "192.168.10.49" }, n)
        shard        = tonumber(regex("shard([0-9])", n)[0])
        replica      = tonumber(regex("rep([0-9])", n)[0])
        https_port   = 8443
        native_tls   = 9440
      }
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.5 envs/analytics-clickhouse/ state -- 9 ClickHouse VMs (3 Keeper + 6 data) + overlays.
    Apply order:
      1. nexus-infra-vmware: pwsh -File scripts/foundation.ps1 apply (dhcp reservations + round-robin DNS + NFS export).
      2. nexus-infra-vmware: pwsh -File scripts/security.ps1   apply (clickhouse-server PKI role + 9 AppRole sidecars + KV seeds).
      3. packer build packer/analytics-clickhouse-keeper-node + packer/analytics-clickhouse-server-node.
      4. This env:           pwsh -File scripts/analytics-clickhouse.ps1 apply  (OR: terraform apply from this dir).
      5. Smoke:              pwsh -File scripts/smoke-0.G.5.ps1.
    Selective ops: -Vars enable_ch_<node>=false (per-VM) or enable_<overlay>=false (per-step).
  EOT
}

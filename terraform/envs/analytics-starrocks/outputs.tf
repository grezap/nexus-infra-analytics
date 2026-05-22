# nexus-infra-analytics / terraform / envs / analytics-starrocks / outputs.tf

output "starrocks_topology" {
  description = "StarRocks cluster topology: 3 FE (BDB-JE quorum) + 3 BE. Reach FE via round-robin DNS starrocks-fe.nexus.lab (MySQL :9030, HTTP :8030) or per-node VMnet11 IPs. No VIP (ADR-0031)."
  value = {
    front_door = "starrocks-fe.nexus.lab (round-robin over the 3 FE; no VIP -- ADR-0031)"
    fe = {
      for n in ["sr-fe-leader", "sr-fe-follower-1", "sr-fe-follower-2"] : n => {
        service_ip   = lookup({ "sr-fe-leader" = "192.168.70.31", "sr-fe-follower-1" = "192.168.70.32", "sr-fe-follower-2" = "192.168.70.33" }, n)
        backplane_ip = lookup({ "sr-fe-leader" = "192.168.10.31", "sr-fe-follower-1" = "192.168.10.32", "sr-fe-follower-2" = "192.168.10.33" }, n)
        query_port   = 9030
        http_port    = 8030
        edit_log     = 9010
        rpc_port     = 9020
      }
    }
    be = {
      for n in ["sr-be-1", "sr-be-2", "sr-be-3"] : n => {
        service_ip   = lookup({ "sr-be-1" = "192.168.70.34", "sr-be-2" = "192.168.70.35", "sr-be-3" = "192.168.70.36" }, n)
        backplane_ip = lookup({ "sr-be-1" = "192.168.10.34", "sr-be-2" = "192.168.10.35", "sr-be-3" = "192.168.10.36" }, n)
        be_port      = 9060
        heartbeat    = 9050
        brpc_port    = 8060
        webserver    = 8040
      }
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.6 envs/analytics-starrocks/ state -- 6 StarRocks VMs (3 FE + 3 BE) + overlays.
    Apply order:
      1. nexus-infra-vmware: foundation apply (dhcp + round-robin DNS starrocks-fe + NFS extended to BE).
      2. nexus-infra-vmware: security apply   (starrocks-server PKI role + 6 AppRole sidecars + KV seeds).
      3. packer build packer/analytics-starrocks-fe-node + packer/analytics-starrocks-be-node.
      4. This env:           pwsh -File scripts/analytics-starrocks.ps1 apply.
      5. Smoke:              pwsh -File scripts/smoke-0.G.6.ps1.
    Builds AFTER 0.G.5 (ClickHouse) is sealed + its VMs stopped (feedback_minimal_running_vms.md).
  EOT
}

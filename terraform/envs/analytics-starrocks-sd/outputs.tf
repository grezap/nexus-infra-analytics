# nexus-infra-analytics / terraform / envs / analytics-starrocks-sd / outputs.tf

output "starrocks_sd_topology" {
  description = "StarRocks shared-data cluster topology: 3 FE (BDB-JE quorum) + 2 CN (stateless compute) + MinIO storage volume (durable). Reach FE via round-robin DNS starrocks-sd-fe.nexus.lab (MySQL :9030, HTTP :8030). No VIP (ADR-0031). SEPARATE from the sealed shared-nothing 0.G.6 cluster (ADR-0037)."
  value = {
    front_door = "starrocks-sd-fe.nexus.lab (round-robin over the 3 FE; no VIP -- ADR-0031)"
    fe = {
      for n in ["sr-sd-fe-1", "sr-sd-fe-2", "sr-sd-fe-3"] : n => {
        service_ip   = lookup({ "sr-sd-fe-1" = "192.168.70.37", "sr-sd-fe-2" = "192.168.70.38", "sr-sd-fe-3" = "192.168.70.39" }, n)
        backplane_ip = lookup({ "sr-sd-fe-1" = "192.168.10.37", "sr-sd-fe-2" = "192.168.10.38", "sr-sd-fe-3" = "192.168.10.39" }, n)
        query_port   = 9030
        http_port    = 8030
        edit_log     = 9010
        rpc_port     = 9020
        cn_meta_port = 6090
      }
    }
    cn = {
      for n in ["sr-sd-cn-1", "sr-sd-cn-2"] : n => {
        service_ip   = lookup({ "sr-sd-cn-1" = "192.168.70.30", "sr-sd-cn-2" = "192.168.70.40" }, n)
        backplane_ip = lookup({ "sr-sd-cn-1" = "192.168.10.30", "sr-sd-cn-2" = "192.168.10.40" }, n)
        cn_port      = 9060
        heartbeat    = 9050
        brpc_port    = 8060
        webserver    = 8040
        starlet_port = 9070
      }
    }
    storage_volume = {
      name       = var.storage_volume_name
      endpoint   = var.minio_endpoint
      bucket     = var.minio_starrocks_bucket
      is_default = true
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.L.5 envs/analytics-starrocks-sd/ state -- 5 StarRocks shared-data VMs (3 FE + 2 CN) + overlays.
    Apply order:
      1. nexus-infra-vmware: foundation apply (extends dhcp + round-robin DNS starrocks-sd-fe with 5 sd nodes).
      2. nexus-infra-vmware: security apply   (starrocks-sd-server PKI role + 5 AppRole sidecars + KV seeds at nexus/analytics/starrocks-sd/* + minio agent policy v2 -- so minio-1 can read SR S3 creds).
      3. nexus-infra-lakehouse lakehouse-minio apply (lakehouse-minio.ps1 apply) -- provisions the `starrocks` bucket + `nexus-starrocks-app` service account + the scoped tenant policy. MinIO 4 VMs must be up.
      4. packer build packer/analytics-starrocks-sd-fe-node + packer/analytics-starrocks-sd-cn-node.
      5. This env:           pwsh -File scripts/analytics-starrocks-sd.ps1 apply.
      6. Smoke:              pwsh -File scripts/smoke-0.L.5.ps1.
    Parallel to the sealed shared-nothing 0.G.6 cluster -- no shared on-host state.
  EOT
}

# nexus-infra-analytics / terraform / envs / analytics-clickhouse / main.tf
#
# Per-cluster Terraform state for the ClickHouse cluster (9 nodes: 3 Keeper at
# .41-.43 + 3 shards x 2 replicas at .44-.49). Per-cluster state + per-engine
# template canon (memory/feedback_per_cluster_state_per_engine_template.md) from
# day one.
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env applied (dnsmasq dhcp-host reservations
#      for the 9 ClickHouse MACs :8A-:92 + round-robin clickhouse.nexus.lab +
#      the /srv/nfs/analytics-backups NFS export).
#   2. nexus-infra-vmware security env applied (clickhouse-server PKI role + 9
#      per-host AppRole sidecars at $HOME\.nexus\vault-agent-analytics-
#      clickhouse-<host>.json + KV sticky-seeds at nexus/analytics/clickhouse/*).
#   3. Packer templates built:
#      H:\VMS\NexusPlatform\_templates\analytics-clickhouse-keeper-node\...vmx
#      H:\VMS\NexusPlatform\_templates\analytics-clickhouse-server-node\...vmx
#
# Apply order within this env:
#   module.ch_keeper_{1..3} + module.ch_shard{1,2,3}_rep{1,2}  (clone + power on;
#       firstboot runs inside each)
#   -> null_resource.clickhouse_nftables_backplane
#   -> null_resource.clickhouse_vault_agent (for_each, 9 nodes)
#   -> null_resource.clickhouse_tls (for_each, 9 nodes)
#   -> null_resource.clickhouse_keeper_config (3 keepers, parallel RAFT start)
#   -> null_resource.clickhouse_server_config (6 data nodes, config.d + start)
#   -> null_resource.clickhouse_schema_bootstrap (one-shot: ON CLUSTER DDL + RBAC + exit gate)
#   -> null_resource.clickhouse_backup_repo (NFS mount + <backups> disk; one-shot)
#
# Wall-clock: ~15-20 min cold apply (most of it per-node SSH polling).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── ClickHouse Keeper quorum (3 nodes) ───────────────────────────────────
# Per nexus-platform-plan/docs/infra/vms.yaml (cluster: clickhouse, phase 0.G.5).
# Dual-NIC: VMnet11 service (DHCP via dhcp-host reservations -> .41-.43) +
# VMnet10 cluster backplane (static per-hostname IP set by firstboot; Keeper
# RAFT 9234 + client 9181 ride here).

module "ch_keeper_1" {
  source = "../../modules/vm"
  count  = var.enable_ch_keeper_1 ? 1 : 0

  vm_name           = "ch-keeper-1"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-keeper-node/analytics-clickhouse-keeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-keeper-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_keeper_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_keeper_1_secondary
}

module "ch_keeper_2" {
  source = "../../modules/vm"
  count  = var.enable_ch_keeper_2 ? 1 : 0

  vm_name           = "ch-keeper-2"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-keeper-node/analytics-clickhouse-keeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-keeper-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_keeper_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_keeper_2_secondary
}

module "ch_keeper_3" {
  source = "../../modules/vm"
  count  = var.enable_ch_keeper_3 ? 1 : 0

  vm_name           = "ch-keeper-3"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-keeper-node/analytics-clickhouse-keeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-keeper-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_keeper_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_keeper_3_secondary
}

# ─── ClickHouse data nodes (3 shards x 2 replicas) ────────────────────────

module "ch_shard1_rep1" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard1_rep1 ? 1 : 0

  vm_name           = "ch-shard1-rep1"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard1-rep1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard1_rep1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard1_rep1_secondary
}

module "ch_shard1_rep2" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard1_rep2 ? 1 : 0

  vm_name           = "ch-shard1-rep2"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard1-rep2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard1_rep2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard1_rep2_secondary
}

module "ch_shard2_rep1" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard2_rep1 ? 1 : 0

  vm_name           = "ch-shard2-rep1"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard2-rep1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard2_rep1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard2_rep1_secondary
}

module "ch_shard2_rep2" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard2_rep2 ? 1 : 0

  vm_name           = "ch-shard2-rep2"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard2-rep2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard2_rep2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard2_rep2_secondary
}

module "ch_shard3_rep1" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard3_rep1 ? 1 : 0

  vm_name           = "ch-shard3-rep1"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard3-rep1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard3_rep1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard3_rep1_secondary
}

module "ch_shard3_rep2" {
  source = "../../modules/vm"
  count  = var.enable_ch_shard3_rep2 ? 1 : 0

  vm_name           = "ch-shard3-rep2"
  template_vmx_path = "${var.template_root}/analytics-clickhouse-server-node/analytics-clickhouse-server-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/ch-shard3-rep2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ch_shard3_rep2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ch_shard3_rep2_secondary
}

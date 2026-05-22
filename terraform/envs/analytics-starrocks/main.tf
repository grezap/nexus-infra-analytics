# nexus-infra-analytics / terraform / envs / analytics-starrocks / main.tf
#
# Per-cluster Terraform state for the StarRocks cluster (6 nodes: 3 FE at
# .31-.33 + 3 BE at .34-.36). Per-cluster state + per-engine template canon.
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env applied (dhcp-host reservations for the
#      6 StarRocks MACs :93-:98 + round-robin starrocks-fe.nexus.lab + the
#      analytics NFS export extended to the 3 BE).
#   2. nexus-infra-vmware security env applied (starrocks-server PKI role + 6
#      per-host AppRole sidecars + KV sticky-seeds at nexus/analytics/starrocks/*).
#   3. Packer templates built (analytics-starrocks-fe-node + analytics-starrocks-be-node).
#
# Apply order:
#   module.sr_fe_* + module.sr_be_*  (clone + power on; firstboot inside)
#   -> null_resource.starrocks_nftables_backplane
#   -> null_resource.starrocks_vault_agent (for_each, 6 nodes)
#   -> null_resource.starrocks_tls (for_each, 6 nodes)
#   -> null_resource.starrocks_fe_bootstrap (leader-first + 2 followers; BDB-JE quorum)
#   -> null_resource.starrocks_be_join (ALTER SYSTEM ADD BACKEND x3)
#   -> null_resource.starrocks_schema_bootstrap (DISTRIBUTED BY HASH BUCKETS + replication_num=3 + RBAC + exit gate)
#   -> null_resource.starrocks_backup_repo (NFS mount + CREATE REPOSITORY + BACKUP/RESTORE SNAPSHOT)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── StarRocks FE quorum (3 nodes: 1 leader bootstrap + 2 followers) ───────
module "sr_fe_leader" {
  source = "../../modules/vm"
  count  = var.enable_sr_fe_leader ? 1 : 0

  vm_name           = "sr-fe-leader"
  template_vmx_path = "${var.template_root}/analytics-starrocks-fe-node/analytics-starrocks-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-fe-leader"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_fe_leader_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_fe_leader_secondary
}

module "sr_fe_follower_1" {
  source = "../../modules/vm"
  count  = var.enable_sr_fe_follower_1 ? 1 : 0

  vm_name           = "sr-fe-follower-1"
  template_vmx_path = "${var.template_root}/analytics-starrocks-fe-node/analytics-starrocks-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-fe-follower-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_fe_follower_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_fe_follower_1_secondary
}

module "sr_fe_follower_2" {
  source = "../../modules/vm"
  count  = var.enable_sr_fe_follower_2 ? 1 : 0

  vm_name           = "sr-fe-follower-2"
  template_vmx_path = "${var.template_root}/analytics-starrocks-fe-node/analytics-starrocks-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-fe-follower-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_fe_follower_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_fe_follower_2_secondary
}

# ─── StarRocks BE tablet plane (3 nodes) ──────────────────────────────────
module "sr_be_1" {
  source = "../../modules/vm"
  count  = var.enable_sr_be_1 ? 1 : 0

  vm_name           = "sr-be-1"
  template_vmx_path = "${var.template_root}/analytics-starrocks-be-node/analytics-starrocks-be-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-be-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_be_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_be_1_secondary
}

module "sr_be_2" {
  source = "../../modules/vm"
  count  = var.enable_sr_be_2 ? 1 : 0

  vm_name           = "sr-be-2"
  template_vmx_path = "${var.template_root}/analytics-starrocks-be-node/analytics-starrocks-be-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-be-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_be_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_be_2_secondary
}

module "sr_be_3" {
  source = "../../modules/vm"
  count  = var.enable_sr_be_3 ? 1 : 0

  vm_name           = "sr-be-3"
  template_vmx_path = "${var.template_root}/analytics-starrocks-be-node/analytics-starrocks-be-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-be-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_be_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_be_3_secondary
}

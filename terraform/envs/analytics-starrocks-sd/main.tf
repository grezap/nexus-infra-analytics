# nexus-infra-analytics / terraform / envs / analytics-starrocks-sd / main.tf
#
# Per-cluster Terraform state for the StarRocks shared-data cluster (5 nodes:
# 3 FE at .37/.38/.39 + 2 CN at .30/.40). Per-cluster state + per-engine
# template canon (memory/feedback_per_cluster_state_per_engine_template.md).
# Built as a SEPARATE cluster from the sealed shared-nothing 0.G.6 one
# (ADR-0037). Phase 0.L.5.
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env applied -- dhcp-host reservations for
#      the 5 MACs (:A5-:A9) at the canonical IPs + round-robin
#      starrocks-sd-fe.nexus.lab DNS record.
#   2. nexus-infra-vmware security env applied -- starrocks-sd-server PKI role
#      + 5 per-host AppRole sidecars + KV sticky-seeds at
#      nexus/analytics/starrocks-sd/{root,app}-password + s3-{access,secret}-key.
#   3. nexus-infra-lakehouse lakehouse-minio env applied (MinIO 4-node EC up
#      and the starrocks-tenant overlay has provisioned the `starrocks` bucket
#      + `nexus-starrocks-app` service account with the scoped policy).
#   4. Packer templates built (analytics-starrocks-sd-fe-node +
#      analytics-starrocks-sd-cn-node).
#
# Apply order:
#   module.sr_sd_fe_*  + module.sr_sd_cn_*  (clone + power on; firstboot inside)
#   -> null_resource.starrocks_sd_nftables_backplane
#   -> null_resource.starrocks_sd_vault_agent (for_each, 5 nodes)
#   -> null_resource.starrocks_sd_tls         (for_each, 5 nodes)
#   -> null_resource.starrocks_sd_fe_bootstrap     (3 FE in shared_data mode, BDB-JE quorum)
#   -> null_resource.starrocks_sd_cn_join          (ALTER SYSTEM ADD COMPUTE NODE x2)
#   -> null_resource.starrocks_sd_storage_volume   (CREATE STORAGE VOLUME ... TYPE = S3 + SET DEFAULT, on the FE leader)
#   -> null_resource.starrocks_sd_schema_bootstrap (cloud-native table in the storage volume + RBAC + read/write round-trip + S3-side proof)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── StarRocks shared-data FE quorum (3 nodes; 1 leader + 2 followers) ────
module "sr_sd_fe_1" {
  source = "../../modules/vm"
  count  = var.enable_sr_sd_fe_1 ? 1 : 0

  vm_name           = "sr-sd-fe-1"
  template_vmx_path = "${var.template_root}/analytics-starrocks-sd-fe-node/analytics-starrocks-sd-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-sd-fe-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_sd_fe_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_sd_fe_1_secondary
}

module "sr_sd_fe_2" {
  source = "../../modules/vm"
  count  = var.enable_sr_sd_fe_2 ? 1 : 0

  vm_name           = "sr-sd-fe-2"
  template_vmx_path = "${var.template_root}/analytics-starrocks-sd-fe-node/analytics-starrocks-sd-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-sd-fe-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_sd_fe_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_sd_fe_2_secondary
}

module "sr_sd_fe_3" {
  source = "../../modules/vm"
  count  = var.enable_sr_sd_fe_3 ? 1 : 0

  vm_name           = "sr-sd-fe-3"
  template_vmx_path = "${var.template_root}/analytics-starrocks-sd-fe-node/analytics-starrocks-sd-fe-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-sd-fe-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_sd_fe_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_sd_fe_3_secondary
}

# ─── StarRocks shared-data CN data plane (2 nodes; stateless compute) ─────
module "sr_sd_cn_1" {
  source = "../../modules/vm"
  count  = var.enable_sr_sd_cn_1 ? 1 : 0

  vm_name           = "sr-sd-cn-1"
  template_vmx_path = "${var.template_root}/analytics-starrocks-sd-cn-node/analytics-starrocks-sd-cn-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-sd-cn-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_sd_cn_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_sd_cn_1_secondary
}

module "sr_sd_cn_2" {
  source = "../../modules/vm"
  count  = var.enable_sr_sd_cn_2 ? 1 : 0

  vm_name           = "sr-sd-cn-2"
  template_vmx_path = "${var.template_root}/analytics-starrocks-sd-cn-node/analytics-starrocks-sd-cn-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/04-analytics/sr-sd-cn-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_sr_sd_cn_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sr_sd_cn_2_secondary
}

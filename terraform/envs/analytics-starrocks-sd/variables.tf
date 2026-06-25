# nexus-infra-analytics / terraform / envs / analytics-starrocks-sd / variables.tf
#
# Per-cluster Terraform state for the StarRocks shared-data cluster (Phase
# 0.L.5, ADR-0037). 5 nodes (3 FE + 2 CN). Separate from the sealed sn cluster.

# --- Shared paths -----------------------------------------------------------
variable "template_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform\\_templates"
}
variable "vm_output_dir_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform"
}
variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (5 nodes) ─────────────────────────────────────────────
variable "enable_sr_sd_fe_1" {
  type    = bool
  default = true
}
variable "enable_sr_sd_fe_2" {
  type    = bool
  default = true
}
variable "enable_sr_sd_fe_3" {
  type    = bool
  default = true
}
variable "enable_sr_sd_cn_1" {
  type    = bool
  default = true
}
variable "enable_sr_sd_cn_2" {
  type    = bool
  default = true
}

# Per-VM MACs (block :A5-:A9, the reserved range between 0.L.3 Spark/ZK :AA-:AE
# and the 0.L.4 registry :AF-:B1). MUST match nexus-infra-vmware foundation
# env's mac_analytics_sr_sd_*_primary.
variable "mac_sr_sd_fe_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A5"
}
variable "mac_sr_sd_fe_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:A5"
}
variable "mac_sr_sd_fe_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A6"
}
variable "mac_sr_sd_fe_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:A6"
}
variable "mac_sr_sd_fe_3_primary" {
  type    = string
  default = "00:50:56:3F:00:A7"
}
variable "mac_sr_sd_fe_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:A7"
}
variable "mac_sr_sd_cn_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A8"
}
variable "mac_sr_sd_cn_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:A8"
}
variable "mac_sr_sd_cn_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A9"
}
variable "mac_sr_sd_cn_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:A9"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_starrocks_sd_vault_agents" {
  type    = bool
  default = true
}
variable "enable_sr_sd_fe_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_sd_fe_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_sd_fe_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_sd_cn_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_sd_cn_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_starrocks_sd_tls" {
  type    = bool
  default = true
}
variable "enable_sd_fe_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-sd-fe-bootstrap.tf -- render fe.conf with run_mode=shared_data + cloud_native_meta_port + bootstrap the leader + join the 2 followers (ALTER SYSTEM ADD FOLLOWER + first start --helper). BDB-JE quorum."
}
variable "enable_sd_cn_join" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-sd-cn-join.tf -- render cn.conf + start the 2 CN + ALTER SYSTEM ADD COMPUTE NODE on the FE leader."
}
variable "enable_sd_storage_volume" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-sd-storage-volume.tf -- CREATE STORAGE VOLUME ... TYPE = S3 LOCATIONS = ('s3://starrocks/') ... + SET AS DEFAULT, executed on the FE leader. Imports the Vault CA into the JDK truststore first so the FE can validate MinIO TLS."
}
variable "enable_sd_schema_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-sd-schema-bootstrap.tf -- one-shot exit gate: CREATE DATABASE/TABLE in the default (cloud-native) storage volume + RBAC + write/read round-trip + S3-side proof that data lives in the MinIO storage volume."
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────
variable "analytics_node_user" {
  type    = string
  default = "nexusadmin"
}
variable "analytics_cluster_timeout_minutes" {
  type    = number
  default = 25
}
variable "vault_agent_version" {
  type    = string
  default = "1.18.5"
}
variable "vault_agent_starrocks_sd_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_starrocks_sd_role_name" {
  type    = string
  default = "starrocks-sd-server"
}

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_root_password_path" {
  type        = string
  default     = "nexus/analytics/starrocks-sd/root-password"
  description = "Vault KV path holding the StarRocks shared-data root SQL user password (field `password`)."
}
variable "kv_app_password_path" {
  type        = string
  default     = "nexus/analytics/starrocks-sd/app-password"
  description = "Vault KV path holding the least-priv app SQL user password (field `password`)."
}
variable "kv_s3_access_key_path" {
  type        = string
  default     = "nexus/analytics/starrocks-sd/s3-access-key"
  description = "Vault KV path holding the MinIO storage-volume access key (fixed 'nexus-starrocks-app', field `value`)."
}
variable "kv_s3_secret_key_path" {
  type        = string
  default     = "nexus/analytics/starrocks-sd/s3-secret-key"
  description = "Vault KV path holding the MinIO storage-volume secret key (40-char hex, field `value`)."
}

# ─── MinIO storage volume target (ADR-0037) ──────────────────────────────
variable "minio_endpoint" {
  type        = string
  default     = "https://minio.nexus.lab:9000"
  description = "MinIO S3 endpoint used in CREATE STORAGE VOLUME. TLS-only (path-style; SAN covers minio.nexus.lab)."
}
variable "minio_starrocks_bucket" {
  type        = string
  default     = "starrocks"
  description = "MinIO bucket holding the internal cloud-native table tree. Created + scoped by nexus-infra-lakehouse's role-overlay-minio-starrocks-tenant.tf."
}
variable "storage_volume_name" {
  type        = string
  default     = "nexus_minio_starrocks"
  description = "StarRocks storage volume name. SET AS DEFAULT STORAGE VOLUME after creation so cloud-native tables land in MinIO without an explicit STORAGE VOLUME clause."
}

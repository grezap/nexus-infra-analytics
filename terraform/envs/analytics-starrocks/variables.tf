# nexus-infra-analytics / terraform / envs / analytics-starrocks / variables.tf

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
  # Non-(x86) path: a VMware Workstation upgrade relocated vmrun.exe out of
  # Program Files (x86); the old x86 default broke clone/power_on + left the stale
  # path in clone_vm state (feedback_vmrun_path_moved_nonx86 /
  # feedback_stale_vmrun_path_in_clone_vm_state). Corrected default baked at the
  # v0.6.5 cold-rebuild 2026-06-12 (mirrors the analytics-clickhouse fix).
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (6 nodes) ─────────────────────────────────────────────
variable "enable_sr_fe_leader" {
  type    = bool
  default = true
}
variable "enable_sr_fe_follower_1" {
  type    = bool
  default = true
}
variable "enable_sr_fe_follower_2" {
  type    = bool
  default = true
}
variable "enable_sr_be_1" {
  type    = bool
  default = true
}
variable "enable_sr_be_2" {
  type    = bool
  default = true
}
variable "enable_sr_be_3" {
  type    = bool
  default = true
}

# Per-VM MACs (block :93-:98, the contiguous range after ClickHouse :8A-:92).
# MUST match nexus-infra-vmware foundation env's mac_analytics_sr_*_primary.
variable "mac_sr_fe_leader_primary" {
  type    = string
  default = "00:50:56:3F:00:93"
}
variable "mac_sr_fe_leader_secondary" {
  type    = string
  default = "00:50:56:3F:01:93"
}
variable "mac_sr_fe_follower_1_primary" {
  type    = string
  default = "00:50:56:3F:00:94"
}
variable "mac_sr_fe_follower_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:94"
}
variable "mac_sr_fe_follower_2_primary" {
  type    = string
  default = "00:50:56:3F:00:95"
}
variable "mac_sr_fe_follower_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:95"
}
variable "mac_sr_be_1_primary" {
  type    = string
  default = "00:50:56:3F:00:96"
}
variable "mac_sr_be_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:96"
}
variable "mac_sr_be_2_primary" {
  type    = string
  default = "00:50:56:3F:00:97"
}
variable "mac_sr_be_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:97"
}
variable "mac_sr_be_3_primary" {
  type    = string
  default = "00:50:56:3F:00:98"
}
variable "mac_sr_be_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:98"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_starrocks_vault_agents" {
  type    = bool
  default = true
}
variable "enable_sr_fe_leader_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_fe_follower_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_fe_follower_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_be_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_be_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_sr_be_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_starrocks_tls" {
  type    = bool
  default = true
}
variable "enable_fe_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-fe-bootstrap.tf -- render fe.conf + bootstrap the leader + join the 2 followers (ALTER SYSTEM ADD FOLLOWER + first start --helper); BDB-JE quorum."
}
variable "enable_be_join" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-be-join.tf -- render be.conf + start the 3 BE + ALTER SYSTEM ADD BACKEND on the FE leader."
}
variable "enable_schema_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-schema-bootstrap.tf -- one-shot exit gate: CREATE DATABASE/TABLE DISTRIBUTED BY HASH BUCKETS n + replication_num=3 + RBAC + tablet-distribution/replication proof."
}
variable "enable_backup_repo" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-backup-repo.tf -- mount the NFS export + CREATE REPOSITORY + BACKUP/RESTORE SNAPSHOT round-trip (ADR-0032)."
}

variable "enable_starrocks_operator_user" {
  type        = bool
  default     = true
  description = "role-overlay-starrocks-operator-user.tf -- idempotently CREATE USER nexus-cluster-admin (cluster_admin+db_admin+user_admin, DEFAULT ROLE ALL) from Vault KV operator-password. The dedicated operator the nexus-cli StarRocksAdapter (v0.6.5) authenticates as. Distinct from the schema-bootstrap root/app users."
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
variable "vault_agent_starrocks_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_starrocks_role_name" {
  type    = string
  default = "starrocks-server"
}

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_root_password_path" {
  type        = string
  default     = "nexus/analytics/starrocks/root-password"
  description = "Vault KV path holding the StarRocks root user password (set on the FE after bootstrap)."
}
variable "kv_app_password_path" {
  type        = string
  default     = "nexus/analytics/starrocks/app-password"
  description = "Vault KV path holding the least-priv app user password."
}

variable "kv_operator_password_path" {
  type        = string
  default     = "nexus/analytics/starrocks/operator-password"
  description = "Vault KV path holding the nexus-cluster-admin operator password (sticky-seeded by security env v2). The nexus-cli StarRocksAdapter authenticates as this dedicated operator; role-overlay-starrocks-operator-user.tf reads it on-node via the agent token to CREATE USER."
}

# ─── Backup repository (NFS from nexus-gateway, ADR-0032) ─────────────────
variable "backup_nfs_server" {
  type    = string
  default = "192.168.70.1"
}
variable "backup_nfs_export" {
  type    = string
  default = "/srv/nfs/analytics-backups"
}
variable "backup_mount_point" {
  type    = string
  default = "/var/backups/analytics"
}

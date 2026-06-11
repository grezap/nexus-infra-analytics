# nexus-infra-analytics / terraform / envs / analytics-clickhouse / variables.tf
#
# Per-cluster ClickHouse state. Per-engine template + per-cluster state canon
# (memory/feedback_per_cluster_state_per_engine_template.md).

# --- Shared paths -----------------------------------------------------------

variable "template_root" {
  type        = string
  description = "Root directory of Packer-built .vmx templates."
  default     = "H:\\VMS\\NexusPlatform\\_templates"
}

variable "vm_output_dir_root" {
  type        = string
  description = "Root directory under which per-VM clone subdirs live (per feedback_vmware_per_vm_folders.md)."
  default     = "H:\\VMS\\NexusPlatform"
}

variable "vmrun_path" {
  type        = string
  default     = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
  description = "Absolute path to vmrun.exe (used by modules/vm). Non-(x86) path: a VMware Workstation upgrade relocated vmrun.exe out of Program Files (x86); the old x86 default broke clone/power_on + left the stale path in clone_vm state (feedback_vmrun_path_moved_nonx86 / feedback_stale_vmrun_path_in_clone_vm_state). Corrected default baked at the v0.6.4 cold-rebuild 2026-06-11."
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + ClickHouse HTTPS 8443 + native-TLS 9440)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- inter-server replication (9010) + native (9440) + Keeper (9181/9234). Static IP per hostname in analytics-node-firstboot.sh."
}

# ─── Per-VM toggles (9 nodes) ─────────────────────────────────────────────
variable "enable_ch_keeper_1" {
  type    = bool
  default = true
}
variable "enable_ch_keeper_2" {
  type    = bool
  default = true
}
variable "enable_ch_keeper_3" {
  type    = bool
  default = true
}
variable "enable_ch_shard1_rep1" {
  type    = bool
  default = true
}
variable "enable_ch_shard1_rep2" {
  type    = bool
  default = true
}
variable "enable_ch_shard2_rep1" {
  type    = bool
  default = true
}
variable "enable_ch_shard2_rep2" {
  type    = bool
  default = true
}
variable "enable_ch_shard3_rep1" {
  type    = bool
  default = true
}
variable "enable_ch_shard3_rep2" {
  type    = bool
  default = true
}

# Per-VM MACs MUST match nexus-infra-vmware foundation env's
# mac_analytics_*_primary defaults (dhcp-host reservations pin those MACs to
# .41-.49 on VMnet11). Block :8A-:92 (the contiguous range after OLTP :89).
# Secondary NIC = same sixth byte, fifth byte 0x01 (VMnet10 backplane).

variable "mac_ch_keeper_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:8A"
  description = "ch-keeper-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.41."
}
variable "mac_ch_keeper_1_secondary" {
  type        = string
  default     = "00:50:56:3F:01:8A"
  description = "ch-keeper-1 secondary NIC MAC (VMnet10). firstboot assigns 192.168.10.41."
}
variable "mac_ch_keeper_2_primary" {
  type    = string
  default = "00:50:56:3F:00:8B"
}
variable "mac_ch_keeper_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:8B"
}
variable "mac_ch_keeper_3_primary" {
  type    = string
  default = "00:50:56:3F:00:8C"
}
variable "mac_ch_keeper_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:8C"
}
variable "mac_ch_shard1_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:8D"
}
variable "mac_ch_shard1_rep1_secondary" {
  type    = string
  default = "00:50:56:3F:01:8D"
}
variable "mac_ch_shard1_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:8E"
}
variable "mac_ch_shard1_rep2_secondary" {
  type    = string
  default = "00:50:56:3F:01:8E"
}
variable "mac_ch_shard2_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:8F"
}
variable "mac_ch_shard2_rep1_secondary" {
  type    = string
  default = "00:50:56:3F:01:8F"
}
variable "mac_ch_shard2_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:90"
}
variable "mac_ch_shard2_rep2_secondary" {
  type    = string
  default = "00:50:56:3F:01:90"
}
variable "mac_ch_shard3_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:91"
}
variable "mac_ch_shard3_rep1_secondary" {
  type    = string
  default = "00:50:56:3F:01:91"
}
variable "mac_ch_shard3_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:92"
}
variable "mac_ch_shard3_rep2_secondary" {
  type    = string
  default = "00:50:56:3F:01:92"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-clickhouse-nftables-backplane.tf -- push the per-cluster nftables ruleset to all 9 nodes."
}

variable "enable_clickhouse_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-clickhouse-vault-agents.tf -- install nexus-vault-agent.service on all 9 nodes."
}

variable "enable_ch_keeper_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_keeper_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_keeper_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard1_rep1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard1_rep2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard2_rep1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard2_rep2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard3_rep1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_ch_shard3_rep2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_clickhouse_tls" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-tls.tf -- per-host Vault Agent PKI template -> server.crt/server.key/ca.crt (PKCS#8) in each node's role-appropriate TLS dir."
}

variable "enable_keeper_config" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-keeper-config.tf -- render keeper_config.xml on the 3 Keeper nodes + parallel RAFT start + quorum wait."
}

variable "enable_server_config" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-server-config.tf -- render /etc/clickhouse-server/config.d/*.xml (remote_servers + macros + zookeeper->Keeper + TLS + listen) + users.d/ + start nexus-clickhouse-server.service on the 6 data nodes."
}

variable "enable_schema_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-schema-bootstrap.tf -- one-shot exit gate: CREATE DATABASE/TABLE ON CLUSTER (ReplicatedMergeTree + Distributed) + RBAC users/roles + Distributed fan-out + replica-convergence round-trip (0.G.5 exit gate)."
}

variable "enable_backup_repo" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-backup-repo.tf -- mount the nexus-gateway NFS export at /var/backups/analytics on the 6 data nodes + register the <backups> Disk + BACKUP/RESTORE round-trip (ADR-0032)."
}

variable "enable_clickhouse_operator_user" {
  type        = bool
  default     = true
  description = "role-overlay-clickhouse-operator-user.tf -- idempotently CREATE USER nexus-cluster-admin ON CLUSTER (sha256_password from Vault KV operator-password) + GRANT ALL WITH GRANT OPTION. The dedicated operator the nexus-cli ClickHouseAdapter (v0.6.4) authenticates as. Distinct from the schema-bootstrap `admin` user."
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────

variable "analytics_node_user" {
  type        = string
  default     = "nexusadmin"
  description = "SSH user on every analytics-node clone (set by Packer preseed)."
}

variable "analytics_cluster_timeout_minutes" {
  type        = number
  default     = 20
  description = "Generous timeout for slow per-node convergence steps (firstboot wait, vault-agent install, TLS render, Keeper quorum, cluster formation)."
}

variable "vault_agent_version" {
  type        = string
  default     = "1.18.5"
  description = "Vault Agent version installed by role-overlay-clickhouse-vault-agents.tf."
}

variable "vault_agent_clickhouse_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 9 vault-agent-analytics-clickhouse-<host>.json AppRole sidecars (written by nexus-infra-vmware security env)."
}

variable "vault_pki_ca_bundle_path" {
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
  description = "Vault PKI CA bundle on the build host (written by nexus-infra-vmware security env's PKI distribute step)."
}

variable "vault_pki_clickhouse_role_name" {
  type        = string
  default     = "clickhouse-server"
  description = "Vault PKI role under pki_int/ that issues leaf certs for all 9 ClickHouse nodes. Must match the role created in nexus-infra-vmware's security env."
}

# ─── ClickHouse cluster shape ─────────────────────────────────────────────

variable "clickhouse_cluster_name" {
  type        = string
  default     = "nexus_analytics"
  description = "The remote_servers cluster name (used in Distributed table DDL + ON CLUSTER)."
}

variable "clickhouse_keeper_client_port" {
  type    = number
  default = 9181
}

variable "clickhouse_keeper_raft_port" {
  type    = number
  default = 9234
}

# KV paths for SQL-driven RBAC creds (sticky-seeded by the security env). The
# overlay reads these via the on-node Vault Agent token (never printed).
variable "kv_admin_password_path" {
  type        = string
  default     = "nexus/analytics/clickhouse/admin-password"
  description = "Vault KV path holding the ClickHouse admin user password (sticky-seeded by security env)."
}

variable "kv_app_password_path" {
  type        = string
  default     = "nexus/analytics/clickhouse/app-password"
  description = "Vault KV path holding the least-priv app role's user password (sticky-seeded by security env)."
}

variable "kv_operator_password_path" {
  type        = string
  default     = "nexus/analytics/clickhouse/operator-password"
  description = "Vault KV path holding the nexus-cluster-admin operator password (sticky-seeded by security env v2). The nexus-cli ClickHouseAdapter authenticates as this dedicated operator; role-overlay-clickhouse-operator-user.tf reads it on-node via the agent token to CREATE USER ... IDENTIFIED WITH sha256_password."
}

# ─── Backup repository (NFS from nexus-gateway, ADR-0032) ─────────────────

variable "backup_nfs_server" {
  type        = string
  default     = "192.168.70.1"
  description = "nexus-gateway VMnet11 IP exporting the analytics backup repository."
}

variable "backup_nfs_export" {
  type        = string
  default     = "/srv/nfs/analytics-backups"
  description = "NFSv4 export real path for analytics backups. The portainer export already holds fsid=0 (the NFSv4 pseudo-root) on /srv/nfs/portainer-data, so the analytics export gets its own non-zero fsid and is mounted via its real path. If the single-fsid=0-pseudo-root semantics block this sibling export at live ratification, the documented fix (handbook §3.x) is to set the gateway pseudo-root to /srv/nfs (crossmnt) with portainer-data + analytics-backups as subdirs."
}

variable "backup_mount_point" {
  type        = string
  default     = "/var/backups/analytics"
  description = "Local mount point on each data node for the shared backup repository."
}

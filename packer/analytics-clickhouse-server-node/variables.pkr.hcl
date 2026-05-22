/*
 * analytics-clickhouse-server-node -- Packer template variables (Phase 0.G.5)
 *
 * Per-engine template per memory/feedback_per_cluster_state_per_engine_
 * template.md: installs clickhouse-server + clickhouse-client. Keeper ships in
 * the sibling analytics-clickhouse-keeper-node template.
 */

variable "vm_name" {
  type        = string
  default     = "analytics-clickhouse-server-node"
  description = "VM display name and output .vmx basename. Default is the template name; per-clone names (ch-shard{1,2,3}-rep{1,2}) are set by terraform/envs/analytics-clickhouse/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/analytics-clickhouse-server-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
  description = "Debian 13.5.0 netinst ISO. Override via `-var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` for the local cache (memory/project_iso_directory.md)."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "clickhouse_version" {
  type        = string
  default     = "latest"
  description = "ClickHouse version from the vendor apt repo. `latest` installs current stable clickhouse-server + clickhouse-client (kept in lockstep with the keeper template's version). To pin, set e.g. `24.8.4.13`. Exact installed version recorded in docs/verification/0.G.5-clickhouse.md at ratification."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "Build-time vCPU. Matches the steady-state ch-shard-rep spec (vms.yaml: 4 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 6144
  description = "Build-time RAM (MB). Default 6 GB per memory/feedback_prefer_less_memory.md (right-sized from the canon 16 GB; ReplicatedMergeTree merge + mark cache fit at lab data volumes -- mark_cache_size tuned in the server-config overlay). Production sizing reverts to 16 GB."
}

variable "disk_gb" {
  type        = number
  default     = 300
  description = "Disk size in GB. Matches canon (vms.yaml: 300 GB) for the ReplicatedMergeTree data set. Growable single-file VMDK only consumes what it writes, so a 300 GB ceiling costs nothing until written."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}

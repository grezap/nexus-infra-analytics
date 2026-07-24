/*
 * analytics-clickhouse-keeper-node -- Packer template variables (Phase 0.G.5)
 *
 * Per-engine template per memory/feedback_per_cluster_state_per_engine_
 * template.md: installs ONLY ClickHouse Keeper. clickhouse-server ships in
 * the sibling analytics-clickhouse-server-node template.
 */

variable "vm_name" {
  type        = string
  default     = "analytics-clickhouse-keeper-node"
  description = "VM display name and output .vmx basename. Default is the template name; per-clone names (ch-keeper-1..3) are set by terraform/envs/analytics-clickhouse/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/analytics-clickhouse-keeper-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type    = string
  default = "H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso"
  # Local ISO from the lab canon dir (H:/VMS/ISO/, project_iso_directory). The
  # upstream mirror rotates point releases off iso-cd/ into archive within months
  # (13.5.0 already 404s there as of 2026-07), so a remote default breaks replay;
  # the checksum below still pins integrity. For a fresh host, fetch the ISO into
  # H:/VMS/ISO/ once (or override -var iso_url=<url> against the archive mirror).
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst -- same value as the oltp per-engine templates."
}

variable "clickhouse_version" {
  type        = string
  default     = "latest"
  description = "ClickHouse Keeper version from the ClickHouse vendor apt repo (packages.clickhouse.com/deb stable main). `latest` (the default) installs the current stable clickhouse-keeper. To pin, set e.g. `24.8.4.13` and the apt task installs `clickhouse-keeper=<version>`. The exact installed version is recorded in docs/verification/0.G.5-clickhouse.md at ratification."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU. Matches the steady-state ch-keeper spec (vms.yaml)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (ClickHouse Keeper is a lightweight C++ RAFT coordinator -- right-sized from the canon 4 GB; logged in vms.yaml). Production sizing reverts to 4 GB."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "Disk size in GB. Default 40 GB sized for the Keeper RAFT log + snapshots at lab scale. Growable single-file VMDK only consumes what it writes."
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

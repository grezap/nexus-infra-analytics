/*
 * analytics-starrocks-be-node -- Packer template variables (Phase 0.G.6)
 *
 * Per-engine template: installs a JDK + the StarRocks BE (Backend) from the
 * StarRocks release tarball. The FE ships in the sibling analytics-starrocks-
 * fe-node template.
 */

variable "vm_name" {
  type        = string
  default     = "analytics-starrocks-be-node"
  description = "VM display name + output .vmx basename. Per-clone names (sr-be-1/2/3) set by terraform/envs/analytics-starrocks/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/analytics-starrocks-be-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
  description = "Debian 13.5.0 netinst ISO. Override via `-var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` for the local cache."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "starrocks_version" {
  type        = string
  default     = "3.3.5"
  description = "StarRocks release version (kept in lockstep with the FE template). Exact version + sha recorded at ratification."
}

variable "starrocks_download_url" {
  type        = string
  default     = "https://releases.starrocks.io/starrocks/StarRocks-3.3.5.tar.gz"
  description = "StarRocks release tarball URL (contains fe/ + be/). MUST match starrocks_version. Override to a local mirror if needed."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-17-jre-headless"
  description = "JDK package present on the BE node (BE is C++ but its tooling/agent expects Java available). Installed from Debian apt by the analytics_starrocks_be role."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "Build-time vCPU (matches the sr-be spec, vms.yaml: 4 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 6144
  description = "Build-time RAM (MB). Default 6 GB per memory/feedback_prefer_less_memory.md (right-sized from canon 16 GB; the BE scan/agg working set fits at lab data volumes). Production reverts to 16 GB."
}

variable "disk_gb" {
  type        = number
  default     = 300
  description = "Disk size in GB (matches canon: 300 GB for the BE tablet storage). Growable VMDK only consumes what it writes."
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

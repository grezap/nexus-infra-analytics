/*
 * analytics-starrocks-fe-node -- Packer template variables (Phase 0.G.6)
 *
 * Per-engine template: installs a JDK + the StarRocks FE (Frontend) from the
 * StarRocks release tarball. The BE ships in the sibling analytics-starrocks-
 * be-node template.
 */

variable "vm_name" {
  type        = string
  default     = "analytics-starrocks-fe-node"
  description = "VM display name + output .vmx basename. Per-clone names (sr-fe-leader / sr-fe-follower-1/2) set by terraform/envs/analytics-starrocks/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/analytics-starrocks-fe-node"
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
  description = "StarRocks release version (FE + BE kept in lockstep across the two templates). Default a 3.3 LTS-line release. The exact version + tarball sha is recorded in docs/verification/0.G.6-starrocks.md at ratification; override if the default patch is unavailable at build time."
}

variable "starrocks_download_url" {
  type        = string
  default     = "https://releases.starrocks.io/starrocks/StarRocks-3.3.5.tar.gz"
  description = "StarRocks release tarball URL (contains fe/ + be/). MUST match starrocks_version. Override to a local mirror (H:/VMS/ISO/ or an internal cache) if releases.starrocks.io is slow/unreachable at build time."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-17-jre-headless"
  description = "JDK package the FE runs on (StarRocks FE requires Java 11+; 17 is current + supported). Installed from Debian apt by the analytics_starrocks_fe role."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the sr-fe spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM (MB). Default 4 GB per memory/feedback_prefer_less_memory.md (right-sized from canon 8 GB; the FE JVM heap is set proportionally in fe.conf). Production reverts to 8 GB."
}

variable "disk_gb" {
  type        = number
  default     = 60
  description = "Disk size in GB (matches canon; FE meta is small)."
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

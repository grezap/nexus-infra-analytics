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
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "starrocks_version" {
  type        = string
  default     = "3.5.17"
  description = "StarRocks release version (FE + BE kept in lockstep across the two templates). Default the latest 3.5 stable-line patch. NOTE: releases are now OS-split -- the tarball is StarRocks-<ver>-ubuntu-amd64.tar.gz (Debian uses the ubuntu build); the old no-suffix StarRocks-<ver>.tar.gz 404/403s. The current per-line patches are listed by the portal API https://download.starrocks.io/en-US/download/releases (md5 in each entry)."
}

variable "starrocks_download_url" {
  type        = string
  default     = "https://releases.starrocks.io/starrocks/StarRocks-3.5.17-ubuntu-amd64.tar.gz"
  description = "StarRocks release binary tarball URL (contains fe/ + be/ + apache_hdfs_broker/). MUST match starrocks_version. A verified copy is cached at H:/VMS/ISO/StarRocks-3.5.17-ubuntu-amd64.tar.gz (md5 954072ebfcbf89bf477a32e872d30baf). releases.starrocks.io serves the LISTED versions only (3.3.5 was superseded by 3.3.22); discover current URLs via the portal API https://download.starrocks.io/en-US/download/releases."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-21-jre-headless"
  description = "JDK package the FE runs on. StarRocks 3.5 requires 'JDK 17 or later' (3.5.0 dropped version-specific JVM configs). Debian 13/trixie does NOT ship openjdk-17 -- only 21 + 25 -- so we use openjdk-21-jre-headless (>=17, satisfies the requirement). JAVA_HOME = /usr/lib/jvm/java-21-openjdk-amd64."
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

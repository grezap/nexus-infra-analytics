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
  description = "StarRocks release version (kept in lockstep with the FE template). Latest 3.5 stable-line patch. Releases are OS-split: StarRocks-<ver>-ubuntu-amd64.tar.gz (the old no-suffix name 403s)."
}

variable "starrocks_download_url" {
  type        = string
  default     = "https://releases.starrocks.io/starrocks/StarRocks-3.5.17-ubuntu-amd64.tar.gz"
  description = "StarRocks release binary tarball URL (contains fe/ + be/). MUST match starrocks_version. Cached at H:/VMS/ISO/StarRocks-3.5.17-ubuntu-amd64.tar.gz (md5 954072ebfcbf89bf477a32e872d30baf). Discover current URLs via https://download.starrocks.io/en-US/download/releases."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-21-jre-headless"
  description = "JDK package present on the BE node (BE is C++ but its embedded JVM / lake-format readers + Java UDFs expect Java). Debian 13 has no openjdk-17 (only 21 + 25); 21 satisfies StarRocks 3.5's 'JDK 17 or later'. JAVA_HOME = /usr/lib/jvm/java-21-openjdk-amd64."
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

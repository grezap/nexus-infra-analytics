/*
 * analytics-starrocks-sd-cn-node -- Packer template variables (Phase 0.L.5, ADR-0037)
 *
 * Per-engine template: installs a JDK + the StarRocks BE package (which ships
 * the CN binary in be/bin/start_cn.sh) from the release tarball. The FE ships
 * in the sibling analytics-starrocks-sd-fe-node template.
 */

variable "vm_name" {
  type        = string
  default     = "analytics-starrocks-sd-cn-node"
  description = "VM display name + output .vmx basename. Per-clone names (sr-sd-cn-1/2) set by terraform/envs/analytics-starrocks-sd/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/analytics-starrocks-sd-cn-node"
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
  description = "Build-time vCPU (matches the sr-sd-cn spec: 4 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM (MB). Default 4 GB per ADR-0037 canon (CN is stateless compute + local datacache; data lives in the MinIO storage volume, no local tablet replication footprint)."
}

variable "disk_gb" {
  type        = number
  default     = 80
  description = "Disk size in GB. Default 80 GB (CN local datacache; data is durable in MinIO -- no need for the 300 GB BE tablet footprint). Growable VMDK only consumes what it writes."
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

/*
 * analytics-starrocks-be-node -- NexusPlatform StarRocks BE (Backend) node
 * template (Phase 0.G.6).
 *
 * Per-engine template. Installs a JDK + the StarRocks BE from the release
 * tarball. The FE gets its own sibling template (analytics-starrocks-fe-node).
 *
 * Three instances clone into the 04-analytics tier per vms.yaml:
 *   - 0.G.6: sr-be-1/2/3 (tablet storage/compute at .34-.36)
 *
 *   - OS: Debian 13. Default RAM 6 GB (right-sized from canon 16 GB).
 *   - Dual-NIC: ethernet0 = VMnet11 (service: BE webserver 8040),
 *     ethernet1 = VMnet10 (backplane: BE thrift 9060 + heartbeat 9050 + brpc 8060).
 *
 * The BE is unpacked to /opt/starrocks/be; nexus-starrocks-be.service is
 * delivered DISABLED (the Terraform be-join overlay renders be.conf with the
 * per-host priority_networks + storage_root_path, then joins via ALTER SYSTEM
 * ADD BACKEND on the FE leader). firstboot writes the node identity.
 *
 * Build:   cd packer/analytics-starrocks-be-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "sr-be-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "analytics-starrocks-be-node template (Phase 0.G.6) -- built by Packer; StarRocks BE ${var.starrocks_version} (release tarball) on ${var.jdk_package}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "sr-be-node"
  sources = ["source.vmware-iso.sr-be-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https nfs-common"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/analytics_firstboot",
      "ansible/roles/analytics_starrocks_be",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "analytics_starrocks_version=${var.starrocks_version}",
      "--extra-vars", "analytics_starrocks_download_url=${var.starrocks_download_url}",
      "--extra-vars", "analytics_jdk_package=${var.jdk_package}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- analytics-starrocks-be-node post-install checks ---'",
      "test -x /opt/starrocks/be/bin/start_be.sh",
      "systemctl cat nexus-starrocks-be.service > /dev/null",
      "systemctl cat analytics-node-firstboot.service > /dev/null",
      "systemctl is-enabled analytics-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-starrocks-be.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-starrocks-be.service not disabled at bake' && exit 1)",
      "id starrocks",
      "test -x /sbin/mount.nfs4 || test -x /usr/sbin/mount.nfs4",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}

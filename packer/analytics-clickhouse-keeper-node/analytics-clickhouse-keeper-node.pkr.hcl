/*
 * analytics-clickhouse-keeper-node -- NexusPlatform ClickHouse Keeper node
 * template (Phase 0.G.5).
 *
 * Per-engine template per memory/feedback_per_cluster_state_per_engine_
 * template.md. Installs ONLY ClickHouse Keeper (the dedicated C++ RAFT
 * coordination quorum, NOT ZooKeeper -- ADR-0028). The clickhouse-server
 * data nodes get their own sibling template (analytics-clickhouse-server-node).
 *
 * Three instances clone into the 04-analytics tier per
 * nexus-platform-plan/docs/infra/vms.yaml:
 *   - 0.G.5: ch-keeper-1..3 (3-node Keeper RAFT quorum at .41-.43)
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as the oltp per-engine templates)
 *   - Default RAM: 2 GB (right-sized per memory/feedback_prefer_less_memory.md
 *     from the canon 4 GB; Keeper is a tiny C++ coordinator).
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service), ethernet1 =
 *     VMnet10 (cluster backplane -- Keeper client 9181 + RAFT 9234 run here).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time: single NAT NIC for apt fetch, then
 *     vmx_remove_ethernet_interfaces strips it. clickhouse-keeper installed
 *     from the ClickHouse vendor apt repo; apt-shipped clickhouse-keeper.service
 *     DISABLED + MASKED; canonical nexus-clickhouse-keeper.service delivered
 *     DISABLED (Terraform's keeper-config overlay renders keeper_config.xml
 *     -- which needs the Terraform-time per-host server_id -- then enables it).
 *   - Clone-time (terraform/modules/vm): configure-vm-nic.ps1 writes the
 *     dual-NIC config post-clone.
 *   - First-boot (analytics-node-firstboot.service): NIC discovery, hostname,
 *     VMnet10 static IP, /etc/nexus-clickhouse-keeper/node-identity.env.
 *
 * Build:   cd packer/analytics-clickhouse-keeper-node; packer init .; packer build .
 * See:     docs/handbook.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ─── Source: Debian 13 netinst, VMware Workstation builder ────────────────
source "vmware-iso" "ch-keeper-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

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
    "annotation"           = "analytics-clickhouse-keeper-node template (Phase 0.G.5) -- built by Packer; ClickHouse Keeper ${var.clickhouse_version} (vendor apt)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + ClickHouse Keeper + shared roles ─────────────────
build {
  name    = "ch-keeper-node"
  sources = ["source.vmware-iso.ch-keeper-node"]

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
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https"
    ]
  }

  # Apply the shared nexus_* roles + analytics_firstboot + analytics_clickhouse_keeper.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/analytics_firstboot",
      "ansible/roles/analytics_clickhouse_keeper",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "analytics_clickhouse_version=${var.clickhouse_version}",
    ]
  }

  # Final sanity + cleanup.
  provisioner "shell" {
    inline = [
      "echo '--- analytics-clickhouse-keeper-node post-install checks ---'",
      "test -x /usr/bin/clickhouse-keeper || test -x /usr/bin/clickhouse",
      "clickhouse-keeper --version || /usr/bin/clickhouse keeper --version || true",
      # nexus-clickhouse-keeper.service is INTENTIONALLY DISABLED at template
      # time -- the template has no per-host server_id yet. firstboot writes
      # node-identity.env; Terraform keeper-config overlay renders
      # keeper_config.xml + enables the service per-host.
      "systemctl cat nexus-clickhouse-keeper.service > /dev/null",
      "systemctl cat analytics-node-firstboot.service > /dev/null",
      "systemctl is-enabled analytics-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      # apt-shipped clickhouse-keeper.service MUST be disabled or masked so a
      # cold boot doesn't race nexus-clickhouse-keeper.service. is-enabled on a
      # masked unit emits 'masked' (rc!=0); accept masked|disabled.
      "systemctl is-enabled clickhouse-keeper.service 2>&1 | grep -qE '^(masked|disabled)$' || (echo 'ERROR: clickhouse-keeper.service is not masked/disabled' && exit 1)",
      "id clickhouse",
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

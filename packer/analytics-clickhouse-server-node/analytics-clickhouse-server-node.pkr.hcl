/*
 * analytics-clickhouse-server-node -- NexusPlatform ClickHouse data-node
 * template (Phase 0.G.5).
 *
 * Per-engine template per memory/feedback_per_cluster_state_per_engine_
 * template.md. Installs clickhouse-server + clickhouse-client. The Keeper
 * quorum gets its own sibling template (analytics-clickhouse-keeper-node).
 *
 * Six instances clone into the 04-analytics tier per
 * nexus-platform-plan/docs/infra/vms.yaml:
 *   - 0.G.5: ch-shard{1,2,3}-rep{1,2} (3 shards x 2 replicas at .44-.49)
 *
 *   - OS: Debian 13. Default RAM 6 GB (right-sized from canon 16 GB).
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service: HTTPS 8443 +
 *     native-TLS 9440), ethernet1 = VMnet10 (cluster backplane: interserver
 *     HTTPS 9010 + native 9440 + Keeper client to 9181).
 *
 * Config model: keep the package's /etc/clickhouse-server/ base config.xml +
 * users.xml; the Terraform server-config overlay drops cluster-specific XML
 * into config.d/*.xml (remote_servers, macros, zookeeper->Keeper, TLS, listen)
 * + users.d/*.xml (RBAC). ClickHouse natively merges config.d/ + users.d/, so
 * the overlay only authors the cluster-specific deltas, never the whole config.
 * The apt clickhouse-server.service is MASKED; nexus-clickhouse-server.service
 * (DISABLED at bake) runs the server gated on the TF-rendered config.d marker.
 *
 * Build:   cd packer/analytics-clickhouse-server-node; packer init .; packer build .
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

source "vmware-iso" "ch-server-node" {
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
    "annotation"           = "analytics-clickhouse-server-node template (Phase 0.G.5) -- built by Packer; clickhouse-server ${var.clickhouse_version} (vendor apt)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "ch-server-node"
  sources = ["source.vmware-iso.ch-server-node"]

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
      "ansible/roles/analytics_clickhouse_server",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "analytics_clickhouse_version=${var.clickhouse_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- analytics-clickhouse-server-node post-install checks ---'",
      "test -x /usr/bin/clickhouse-server || test -x /usr/bin/clickhouse",
      "test -x /usr/bin/clickhouse-client",
      "clickhouse-server --version",
      "clickhouse-client --version",
      "systemctl cat nexus-clickhouse-server.service > /dev/null",
      "systemctl cat analytics-node-firstboot.service > /dev/null",
      "systemctl is-enabled analytics-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      # apt-shipped clickhouse-server.service MUST be masked/disabled so cold
      # boot doesn't race nexus-clickhouse-server.service with the plain-port
      # default config.
      "systemctl is-enabled clickhouse-server.service 2>&1 | grep -qE '^(masked|disabled)$' || (echo 'ERROR: clickhouse-server.service is not masked/disabled' && exit 1)",
      # nfs-common present for the backup-repo NFS mount (ADR-0032).
      "test -x /sbin/mount.nfs4 || test -x /usr/sbin/mount.nfs4",
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

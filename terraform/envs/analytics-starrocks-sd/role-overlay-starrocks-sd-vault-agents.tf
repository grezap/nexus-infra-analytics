/*
 * role-overlay-starrocks-vault-agents.tf -- Phase 0.L.5 (ADR-0037)
 *
 * Installs nexus-vault-agent on each of the 5 StarRocks shared-data nodes (3 FE + 3 BE).
 * Port of the ClickHouse vault-agents overlay with StarRocks specifics:
 * sidecar filename vault-agent-analytics-starrocks-sd-<host>.json + the SR node set.
 *
 * Cross-env coupling: reads the AppRole creds JSON sidecars (security env writes
 * them). ERROR (not WARN+skip) if absent.
 *
 * Selective ops: var.enable_starrocks_sd_vault_agents (master) AND per-host
 *                var.enable_<host>_vault_agent.
 */

locals {
  starrocks_sd_vault_agent_specs = {
    "sr-sd-fe-1" = { vm_ip = "192.168.70.37", enabled = var.enable_sr_sd_fe_1_vault_agent }
    "sr-sd-fe-2" = { vm_ip = "192.168.70.38", enabled = var.enable_sr_sd_fe_2_vault_agent }
    "sr-sd-fe-3" = { vm_ip = "192.168.70.39", enabled = var.enable_sr_sd_fe_3_vault_agent }
    "sr-sd-cn-1" = { vm_ip = "192.168.70.30", enabled = var.enable_sr_sd_cn_1_vault_agent }
    "sr-sd-cn-2" = { vm_ip = "192.168.70.40", enabled = var.enable_sr_sd_cn_2_vault_agent }
  }

  starrocks_sd_vault_agent_active = {
    for host, spec in local.starrocks_sd_vault_agent_specs : host => spec
    if var.enable_starrocks_sd_vault_agents && spec.enabled
  }

  sr_sd_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_starrocks_sd_creds_dir, "$HOME", "~"))
  sr_sd_va_ca_bundle_expanded = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "starrocks_sd_vault_agent" {
  for_each = local.starrocks_sd_vault_agent_active

  triggers = {
    creds_file_path    = "${local.sr_sd_va_creds_dir_expanded}/vault-agent-analytics-starrocks-sd-${each.key}.json"
    creds_file_hash    = filesha256("${local.sr_sd_va_creds_dir_expanded}/vault-agent-analytics-starrocks-sd-${each.key}.json")
    nftables_id        = length(null_resource.starrocks_sd_nftables_backplane) > 0 ? null_resource.starrocks_sd_nftables_backplane[0].id : "disabled"
    vault_version      = var.vault_agent_version
    sr_sd_va_overlay_v = "1"

    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.analytics_node_user
  }

  depends_on = [null_resource.starrocks_sd_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vm_ip}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.sr_sd_va_creds_dir_expanded}/vault-agent-analytics-starrocks-sd-${each.key}.json'
      $caBundlePath = '${local.sr_sd_va_ca_bundle_expanded}'
      $sshUser      = '${var.analytics_node_user}'
      $bootTimeout  = ${var.analytics_cluster_timeout_minutes}

      if (-not (Test-Path $credsFile)) {
        throw "[sr-sd-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 5 StarRocks shared-data AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) { throw "[sr-sd-va $hostName] creds JSON missing role_id or secret_id" }
      if (-not (Test-Path $caBundlePath)) { throw "[sr-sd-va $hostName] CA bundle $caBundlePath missing -- run security env apply first." }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[sr-sd-va $hostName] waiting for SSH + firstboot marker..."
      $bootDeadline = (Get-Date).AddMinutes($bootTimeout)
      $booted = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -f /var/lib/analytics-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $booted = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $booted) { throw "[sr-sd-va $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[sr-sd-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[sr-sd-va $hostName] installing Vault Agent v$vaultVersion"
      $installScript = @"
set -euo pipefail
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi
if [ -x /usr/local/bin/vault ] && /usr/local/bin/vault version 2>/dev/null | grep -qF "Vault v$vaultVersion"; then
  echo "vault binary v$vaultVersion already installed"
else
  cd /tmp
  zip="vault_$${vaultVersion}_linux_amd64.zip"
  sums="vault_$${vaultVersion}_SHA256SUMS"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$zip"  -o "`$zip"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$sums" -o "`$sums"
  grep "`$zip" "`$sums" | sha256sum -c -
  unzip -o "`$zip"
  sudo install -m 755 -o root -g root vault /usr/local/bin/vault
  rm -f "`$zip" "`$sums" vault
fi
sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($installScript))
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) { Write-Host $installOut.Trim(); throw "[sr-sd-va $hostName] vault binary install failed (rc=$LASTEXITCODE)" }
      Write-Host $installOut.Trim()

      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        [System.IO.File]::WriteAllText($roleIdTmp.FullName, $roleId)
        [System.IO.File]::WriteAllText($secretIdTmp.FullName, $secretId)
        scp @sshOpts $roleIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/role-id"
        scp @sshOpts $secretIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/secret-id"
        scp @sshOpts $caBundlePath "$${sshUser}@$${vmIp}:/tmp/ca-bundle.crt"
        $stageScript = @"
set -euo pipefail
sudo install -m 0400 -o root -g root /tmp/role-id       /etc/vault-agent/role-id
sudo install -m 0400 -o root -g root /tmp/secret-id     /etc/vault-agent/secret-id
sudo install -m 0644 -o root -g root /tmp/ca-bundle.crt /etc/vault-agent/ca-bundle.crt
sudo rm -f /tmp/role-id /tmp/secret-id /tmp/ca-bundle.crt
"@
        $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stageScript))
        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $stageOut.Trim(); throw "[sr-sd-va $hostName] credential staging failed (rc=$LASTEXITCODE)" }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      $baseConfig = @"
# 00-base.hcl -- Phase 0.L.5 (ADR-0037) (StarRocks mTLS).
pid_file = "/var/run/nexus-vault-agent/agent.pid"
vault {
  address = "$vaultAddr"
  ca_cert = "/etc/vault-agent/ca-bundle.crt"
}
auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/nexus-vault-agent/token"
      mode = 0640
    }
  }
}
"@
      $unitFile = @"
[Unit]
Description=Nexus Vault Agent (Phase 0.L.5 (ADR-0037) -- StarRocks mTLS)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target analytics-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault
[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=nexus-vault-agent
RuntimeDirectoryMode=0755
LogsDirectory=nexus-vault-agent
LogsDirectoryMode=0755
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/
ExecReload=/bin/kill -HUP `$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vault-agent/agent.log
StandardError=append:/var/log/nexus-vault-agent/agent.log
[Install]
WantedBy=multi-user.target
"@
      $configB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($baseConfig))
      $unitB64   = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($unitFile))
      $finalScript = @"
set -euo pipefail
echo '$configB64' | base64 -d | sudo tee /etc/vault-agent/00-base.hcl > /dev/null
sudo chown root:root /etc/vault-agent/00-base.hcl
sudo chmod 0644 /etc/vault-agent/00-base.hcl
echo '$unitB64' | base64 -d | sudo tee /etc/systemd/system/nexus-vault-agent.service > /dev/null
sudo chown root:root /etc/systemd/system/nexus-vault-agent.service
sudo chmod 0644 /etc/systemd/system/nexus-vault-agent.service
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-vault-agent.service
"@
      $finalB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($finalScript))
      $finalOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$finalB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) { Write-Host $finalOut.Trim(); throw "[sr-sd-va $hostName] config/service setup failed (rc=$LASTEXITCODE)" }
      Write-Host $finalOut.Trim()

      Start-Sleep -Seconds 5
      $verifyDeadline = (Get-Date).AddSeconds(30)
      $serviceActive = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nexus-vault-agent.service" 2>&1 | Out-String).Trim()
        if ($status -eq 'active') { $serviceActive = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $serviceActive) {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[sr-sd-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') { throw "[sr-sd-va $hostName] AppRole login appears to have failed (token sink empty)" }
      Write-Host "[sr-sd-va $hostName] nexus-vault-agent.service active; AppRole authenticated"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[sr-sd-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning install-owned files"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -f /etc/vault-agent/00-base.hcl /etc/vault-agent/role-id /etc/vault-agent/secret-id /etc/vault-agent/ca-bundle.crt /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}

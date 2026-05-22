/*
 * role-overlay-clickhouse-tls.tf -- Phase 0.G.5 -- ClickHouse mTLS cert render
 *
 * Drops a per-host Vault Agent PKI template that renders server.crt/server.key/
 * ca.crt into each node's role-appropriate TLS dir:
 *   - Keeper nodes -> /etc/nexus-clickhouse-keeper/tls   (group clickhouse)
 *   - data  nodes  -> /etc/clickhouse-server/tls         (group clickhouse)
 *
 * Port of nexus-infra-oltp's role-overlay-redis-tls.tf. Same choreography
 * (install split script -> drop 60-template-clickhouse-tls.hcl -> restart agent
 * -> wait for bundle.pem -> manual split -> verify CN) and the same hard-won
 * details: PKCS#8 key (Vault PKI issues PKCS#1); ca.crt = intermediate + root
 * (OpenSSL strict X509 needs a self-signed anchor; ClickHouse uses OpenSSL, so
 * like Redis -- not Java/Kafka -- the intermediate alone fails); SSH stdin pipe
 * (feedback_ssh_stage1_size_limit.md); HCL heredoc backtick-escaping
 * (feedback_vault_agent_template_hcl_heredoc.md).
 *
 * The cert SANs include the round-robin DNS name `clickhouse.nexus.lab` so a
 * client doing verify-full against the round-robin endpoint validates
 * regardless of which data node answers (the analytics analogue of the
 * VIP-in-IP-SAN pattern -- ADR-0031).
 *
 * Selective ops: var.enable_clickhouse_tls AND var.enable_clickhouse_vault_agents.
 */

locals {
  # role -> (dest_dir). Keeper + server differ; group is clickhouse for both.
  clickhouse_tls_per_host = {
    "ch-keeper-1"    = { vmnet10 = "192.168.10.41", vmnet11 = "192.168.70.41", role = "keeper", dest_dir = "/etc/nexus-clickhouse-keeper/tls" }
    "ch-keeper-2"    = { vmnet10 = "192.168.10.42", vmnet11 = "192.168.70.42", role = "keeper", dest_dir = "/etc/nexus-clickhouse-keeper/tls" }
    "ch-keeper-3"    = { vmnet10 = "192.168.10.43", vmnet11 = "192.168.70.43", role = "keeper", dest_dir = "/etc/nexus-clickhouse-keeper/tls" }
    "ch-shard1-rep1" = { vmnet10 = "192.168.10.44", vmnet11 = "192.168.70.44", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
    "ch-shard1-rep2" = { vmnet10 = "192.168.10.45", vmnet11 = "192.168.70.45", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
    "ch-shard2-rep1" = { vmnet10 = "192.168.10.46", vmnet11 = "192.168.70.46", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
    "ch-shard2-rep2" = { vmnet10 = "192.168.10.47", vmnet11 = "192.168.70.47", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
    "ch-shard3-rep1" = { vmnet10 = "192.168.10.48", vmnet11 = "192.168.70.48", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
    "ch-shard3-rep2" = { vmnet10 = "192.168.10.49", vmnet11 = "192.168.70.49", role = "server", dest_dir = "/etc/clickhouse-server/tls" }
  }

  clickhouse_tls_active = {
    for host, spec in local.clickhouse_tls_per_host : host => spec
    if(
      var.enable_clickhouse_tls && var.enable_clickhouse_vault_agents
      && lookup(local.clickhouse_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "clickhouse_tls" {
  for_each = local.clickhouse_tls_active

  triggers = {
    va_id            = null_resource.clickhouse_vault_agent[each.key].id
    pki_role_name    = var.vault_pki_clickhouse_role_name
    dest_dir         = each.value.dest_dir
    clickhouse_tls_v = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.analytics_node_user
    destroy_dest_dir = each.value.dest_dir
  }

  depends_on = [null_resource.clickhouse_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $destDir  = '${each.value.dest_dir}'
      $pkiRole  = '${var.vault_pki_clickhouse_role_name}'
      $sshUser  = '${var.analytics_node_user}'
      $cn       = "$hostName.clickhouse.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$hostName.clickhouse.nexus.lab,clickhouse.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[ch-tls $hostName] cert render via Vault Agent PKI template -> $destDir"

      # ─── Split script (literal here-string; takes $1=DEST_DIR $2=GROUP) ────
      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: clickhouse-tls-split.sh DEST_DIR GROUP}"
GROUP="$${2:?usage: clickhouse-tls-split.sh DEST_DIR GROUP}"
BUNDLE="$DEST/bundle.pem"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

LEAF=""; KEY=""; CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*) KEY=$f ;;
    *"BEGIN CERTIFICATE"*) if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi ;;
  esac
done
if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[clickhouse-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2; exit 1
fi

# Vault PKI issues PKCS#1; standardize on PKCS#8 (idempotent).
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

# ca.crt = intermediate ($CA) + root (from the Vault-Agent-distributed bundle).
# ClickHouse uses OpenSSL, which (like Redis, unlike Java/Kafka) needs a
# self-signed anchor in the chain or verification fails "unable to get issuer".
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[clickhouse-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"

install -m 0640 -o root -g "$GROUP" "$LEAF"              "$DEST/server.crt"
install -m 0640 -o root -g "$GROUP" "$TMP/key-pkcs8.pem" "$DEST/server.key"
install -m 0640 -o root -g "$GROUP" "$TMP/ca-chain.pem"  "$DEST/ca.crt"

# World-readable CA chain copy so a CLI run as nexusadmin can chain-verify
# against the round-robin endpoint without traversing the 0750 config dir.
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/clickhouse-ca.pem

echo "[clickhouse-tls-split] $(date -u +%FT%TZ) bundle split -> $DEST/{server.crt,server.key,ca.crt} (intermediate+root)"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── Per-host Vault Agent PKI template ────────────────────────────────
      $vaultAgentTemplate = @"
# 60-template-clickhouse-tls.hcl -- Phase 0.G.5 (rendered for $hostName).
# Issues a ClickHouse leaf from pki_int/roles/$pkiRole, writes one bundle file;
# the post-render command splits it into server.crt + server.key + ca.crt.
template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT
  destination     = "$destDir/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "clickhouse"
  command         = "/usr/local/sbin/clickhouse-tls-split.sh $destDir clickhouse"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
# clickhouse group must exist before the template writes bundle.pem with
# group=clickhouse (the Packer role creates it; defensive create if missing).
if ! getent group clickhouse >/dev/null; then sudo groupadd --system clickhouse; fi
if ! getent passwd clickhouse >/dev/null; then sudo useradd --system --gid clickhouse --no-create-home --shell /usr/sbin/nologin clickhouse; fi

sudo mkdir -p "$destDir"
sudo chown root:clickhouse "$destDir"
sudo chmod 0750 "$destDir"

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/clickhouse-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/clickhouse-tls-split.sh
sudo chmod 0755 /usr/local/sbin/clickhouse-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-clickhouse-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-clickhouse-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-clickhouse-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait for bundle.pem, then run the split manually (pkiCert results are cached
# by the agent so a restart with an unchanged cert won't fire command-on-render).
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s "$destDir/bundle.pem" && break
  sleep 2
done
if ! sudo test -s "$destDir/bundle.pem"; then
  echo "[ch-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/clickhouse-tls-split.sh "$destDir" clickhouse
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[ch-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)"
      }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $destDir/server.crt && sudo test -s $destDir/server.key && sudo test -s $destDir/ca.crt && sudo openssl x509 -in $destDir/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[ch-tls $hostName] cert files not rendered (CN=$cn) within 60s"
      }
      Write-Host "[ch-tls $hostName] cert rendered (CN=$cn); server.crt + server.key + ca.crt in $destDir"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $destDir  = '${self.triggers.destroy_dest_dir}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[ch-tls destroy] $${hostName}: removing 60-template-clickhouse-tls.hcl + cert files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-clickhouse-tls.hcl $destDir/bundle.pem $destDir/server.crt $destDir/server.key $destDir/ca.crt /etc/ssl/certs/clickhouse-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}

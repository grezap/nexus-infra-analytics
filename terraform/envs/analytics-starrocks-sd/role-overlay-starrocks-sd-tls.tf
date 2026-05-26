/*
 * role-overlay-starrocks-tls.tf -- Phase 0.L.5 (ADR-0037) -- StarRocks mTLS cert render
 *
 * Per-host Vault Agent PKI template -> server.crt/server.key/ca.crt (PKCS#8) in
 * each node's role-appropriate TLS dir:
 *   - FE nodes -> /opt/starrocks/fe/conf/tls   (group starrocks)
 *   - BE nodes -> /opt/starrocks/be/conf/tls   (group starrocks)
 *
 * Port of the ClickHouse tls overlay (same split-script + PKCS#8 + ca-chain +
 * SSH-stdin + HCL-heredoc escaping). FE certs carry the round-robin name
 * starrocks-sd-fe.nexus.lab in their SANs (ADR-0031).
 *
 * StarRocks TLS posture (best-effort, ratification-confirmed): the FE MySQL
 * protocol (:9030) supports SSL via a JKS keystore (enable_ssl + ssl_keystore_*
 * in fe.conf); the fe-bootstrap overlay builds a keystore from these PEM files
 * (keytool) when enabling SSL. FE<->BE internal (thrift/brpc) TLS is newer in
 * StarRocks -- the backplane is firewall-trusted (VMnet10) as the lab posture;
 * tightening internal TLS is a documented ratification follow-up (handbook §3.x).
 *
 * Selective ops: var.enable_starrocks_sd_tls AND var.enable_starrocks_sd_vault_agents.
 */

locals {
  starrocks_sd_tls_per_host = {
    "sr-sd-fe-1" = { vmnet10 = "192.168.10.37", vmnet11 = "192.168.70.37", role = "fe", dest_dir = "/opt/starrocks/fe/conf/tls" }
    "sr-sd-fe-2" = { vmnet10 = "192.168.10.38", vmnet11 = "192.168.70.38", role = "fe", dest_dir = "/opt/starrocks/fe/conf/tls" }
    "sr-sd-fe-3" = { vmnet10 = "192.168.10.39", vmnet11 = "192.168.70.39", role = "fe", dest_dir = "/opt/starrocks/fe/conf/tls" }
    "sr-sd-cn-1" = { vmnet10 = "192.168.10.30", vmnet11 = "192.168.70.30", role = "cn", dest_dir = "/opt/starrocks/be/conf/tls" }
    "sr-sd-cn-2" = { vmnet10 = "192.168.10.40", vmnet11 = "192.168.70.40", role = "cn", dest_dir = "/opt/starrocks/be/conf/tls" }
  }

  starrocks_sd_tls_active = {
    for host, spec in local.starrocks_sd_tls_per_host : host => spec
    if(
      var.enable_starrocks_sd_tls && var.enable_starrocks_sd_vault_agents
      && lookup(local.starrocks_sd_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "starrocks_sd_tls" {
  for_each = local.starrocks_sd_tls_active

  triggers = {
    va_id              = null_resource.starrocks_sd_vault_agent[each.key].id
    pki_role_name      = var.vault_pki_starrocks_sd_role_name
    dest_dir           = each.value.dest_dir
    starrocks_sd_tls_v = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.analytics_node_user
    destroy_dest_dir = each.value.dest_dir
  }

  depends_on = [null_resource.starrocks_sd_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $destDir  = '${each.value.dest_dir}'
      $pkiRole  = '${var.vault_pki_starrocks_sd_role_name}'
      $sshUser  = '${var.analytics_node_user}'
      $cn       = "$hostName.starrocks-sd.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$hostName.starrocks-sd.nexus.lab,starrocks-sd-fe.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[sr-sd-tls $hostName] cert render via Vault Agent PKI template -> $destDir"

      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: starrocks-sd-tls-split.sh DEST_DIR GROUP}"
GROUP="$${2:?usage: starrocks-sd-tls-split.sh DEST_DIR GROUP}"
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
  echo "[starrocks-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "$ROOT_BUNDLE" ] || { echo "[starrocks-tls-split] ERROR: $ROOT_BUNDLE missing" >&2; exit 1; }
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"
install -m 0640 -o root -g "$GROUP" "$LEAF"              "$DEST/server.crt"
install -m 0640 -o root -g "$GROUP" "$TMP/key-pkcs8.pem" "$DEST/server.key"
install -m 0640 -o root -g "$GROUP" "$TMP/ca-chain.pem"  "$DEST/ca.crt"
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/starrocks-sd-ca.pem
echo "[starrocks-tls-split] $(date -u +%FT%TZ) bundle split -> $DEST/{server.crt,server.key,ca.crt}"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-starrocks-sd-tls.hcl -- Phase 0.L.5 (ADR-0037) (rendered for $hostName).
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
  group           = "starrocks"
  command         = "/usr/local/sbin/starrocks-sd-tls-split.sh $destDir starrocks"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
if ! getent group starrocks >/dev/null; then sudo groupadd --system starrocks; fi
if ! getent passwd starrocks >/dev/null; then sudo useradd --system --gid starrocks --no-create-home --shell /usr/sbin/nologin starrocks; fi
sudo mkdir -p "$destDir"
sudo chown root:starrocks "$destDir"
sudo chmod 0750 "$destDir"
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/starrocks-sd-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/starrocks-sd-tls-split.sh
sudo chmod 0755 /usr/local/sbin/starrocks-sd-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-starrocks-sd-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-starrocks-sd-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-starrocks-sd-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s "$destDir/bundle.pem" && break
  sleep 2
done
if ! sudo test -s "$destDir/bundle.pem"; then
  echo "[sr-sd-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/starrocks-sd-tls-split.sh "$destDir" starrocks
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[sr-sd-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $destDir/server.crt && sudo openssl x509 -in $destDir/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[sr-sd-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      Write-Host "[sr-sd-tls $hostName] cert rendered (CN=$cn) in $destDir"
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
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-starrocks-sd-tls.hcl $destDir/bundle.pem $destDir/server.crt $destDir/server.key $destDir/ca.crt /etc/ssl/certs/starrocks-sd-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}

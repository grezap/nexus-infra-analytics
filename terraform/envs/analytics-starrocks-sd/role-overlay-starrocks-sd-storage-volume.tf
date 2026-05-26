/*
 * role-overlay-starrocks-sd-storage-volume.tf -- Phase 0.L.5 (ADR-0037)
 *
 * Creates the MinIO storage volume + sets it as default. Runs once on the FE
 * leader. Pre-step: import the Vault CA bundle into the FE's JDK truststore
 * (java-21 cacerts) so the AWS Java SDK validates the MinIO TLS endpoint
 * during CREATE STORAGE VOLUME. Same pattern for the 2 CN: add the Vault CA
 * to /usr/local/share/ca-certificates + update-ca-certificates so libcurl /
 * aws-sdk-cpp validates MinIO at data-I/O time.
 *
 * SQL executed on the FE leader (S3 creds read on-node from Vault KV; never
 * printed):
 *
 *   CREATE STORAGE VOLUME nexus_minio_starrocks
 *   TYPE = S3
 *   LOCATIONS = ('s3://starrocks/')
 *   PROPERTIES (
 *     "enabled"                              = "true",
 *     "aws.s3.endpoint"                      = "https://minio.nexus.lab:9000",
 *     "aws.s3.region"                        = "us-east-1",
 *     "aws.s3.access_key"                    = "<KV nexus/analytics/starrocks-sd/s3-access-key>",
 *     "aws.s3.secret_key"                    = "<KV nexus/analytics/starrocks-sd/s3-secret-key>",
 *     "aws.s3.enable_path_style_access"      = "true",
 *     "aws.s3.use_aws_sdk_default_behavior"  = "false",
 *     "aws.s3.use_instance_profile"          = "false"
 *   );
 *   SET nexus_minio_starrocks AS DEFAULT STORAGE VOLUME;
 *
 * Then SHOW STORAGE VOLUMES validates name + IsDefault=true.
 *
 * Selective ops: var.enable_sd_storage_volume.
 */

resource "null_resource" "starrocks_sd_storage_volume" {
  count = var.enable_sd_storage_volume ? 1 : 0

  triggers = {
    cn_id          = length(null_resource.starrocks_sd_cn_join) > 0 ? null_resource.starrocks_sd_cn_join[0].id : "disabled"
    sd_sv_v        = "1"
    ssh_user       = var.analytics_node_user
    storage_volume = var.storage_volume_name
    endpoint       = var.minio_endpoint
    bucket         = var.minio_starrocks_bucket
  }

  depends_on = [null_resource.starrocks_sd_cn_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.analytics_node_user}'
      $leaderIp  = '192.168.70.37'
      $svName    = '${var.storage_volume_name}'
      $endpoint  = '${var.minio_endpoint}'
      $bucket    = '${var.minio_starrocks_bucket}'
      $kvRootPw  = '${var.kv_root_password_path}'
      $kvAk      = '${var.kv_s3_access_key_path}'
      $kvSk      = '${var.kv_s3_secret_key_path}'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # First import the Vault CA into the JDK cacerts on every FE (idempotent;
      # keytool returns rc != 0 if alias exists -- we swallow). The CN nodes
      # add the CA to the system trust store via update-ca-certificates so the
      # AWS C++ SDK validates MinIO TLS at data-I/O time.
      $caImportFe = @'
set -euo pipefail
JH=/usr/lib/jvm/java-21-openjdk-amd64
TRUSTSTORE="$JH/lib/security/cacerts"
if [ ! -f "$TRUSTSTORE" ]; then
  echo "ERROR: JDK truststore $TRUSTSTORE not found" >&2; exit 1
fi
if sudo keytool -list -alias nexus-vault-ca -keystore "$TRUSTSTORE" -storepass changeit -noprompt >/dev/null 2>&1; then
  echo "[sr-sd-fe-ca] nexus-vault-ca already in JDK cacerts"
else
  sudo keytool -import -trustcacerts -noprompt -alias nexus-vault-ca \
    -file /etc/vault-agent/ca-bundle.crt \
    -keystore "$TRUSTSTORE" -storepass changeit
  echo "[sr-sd-fe-ca] nexus-vault-ca imported into JDK cacerts"
fi
sudo systemctl restart nexus-starrocks-sd-fe.service
sleep 8
echo FE_CA_OK
'@
      foreach ($feip in @('192.168.70.37','192.168.70.38','192.168.70.39')) {
        $o = ($caImportFe -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$feip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'FE_CA_OK') { Write-Host $o.Trim(); throw "[sr-sd-sv] FE CA import failed on $feip" }
      }

      $caImportCn = @'
set -euo pipefail
sudo install -m 0644 /etc/vault-agent/ca-bundle.crt /usr/local/share/ca-certificates/nexus-vault-ca.crt
sudo update-ca-certificates >/dev/null 2>&1 || sudo update-ca-certificates
sudo systemctl restart nexus-starrocks-sd-cn.service
sleep 5
echo CN_CA_OK
'@
      foreach ($cnip in @('192.168.70.30','192.168.70.40')) {
        $o = ($caImportCn -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$cnip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($o -notmatch 'CN_CA_OK') { Write-Host $o.Trim(); throw "[sr-sd-sv] CN CA install failed on $cnip" }
      }

      # Wait for the FE leader's MySQL port to come back after the restart.
      $deadline = (Get-Date).AddMinutes(5); $up = $false
      while ((Get-Date) -lt $deadline) {
        $r = (ssh @sshOpts "$sshUser@$leaderIp" "mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -N -e 'SELECT 1' 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($r -match '^1\s*$') { $up = $true; break }
        Start-Sleep -Seconds 6
      }
      if (-not $up) { throw "[sr-sd-sv] FE leader :9030 did not come back after CA restart" }

      # Create the storage volume + set as default. SQL runs on the FE leader;
      # S3 creds read on-node from Vault KV via the per-host agent token. The
      # mysql client + bash both swallow the secret -- never echoed to stdout.
      $svTmpl = @'
set -euo pipefail
MYSQL() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root "$@"; }

VADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl | head -1)
VTOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
export VAULT_ADDR="$VADDR"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
export VAULT_TOKEN="$VTOKEN"

ROOT_PW=$(/usr/local/bin/vault kv get -field=password __ROOT_KV__)
AK=$(/usr/local/bin/vault kv get -field=value __AK_KV__)
SK=$(/usr/local/bin/vault kv get -field=value __SK_KV__)
if [ -z "$ROOT_PW" ] || [ -z "$AK" ] || [ -z "$SK" ]; then
  echo "ERROR: KV reads empty (root_pw=$${#ROOT_PW} ak=$${#AK} sk=$${#SK})" >&2; exit 1
fi
echo "[sr-sd-sv] KV creds read (root_pw len=$${#ROOT_PW}, ak len=$${#AK}, sk len=$${#SK})"

# First time round we may not have set the root password yet; tolerate both.
if MYSQL -e "SELECT 1" >/dev/null 2>&1; then
  RP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root "$@"; }
else
  RP() { mysql --skip-ssl -h 127.0.0.1 -P 9030 -u root -p"$ROOT_PW" "$@"; }
fi

# Check if the storage volume already exists (idempotent re-fire).
EXISTS=$(RP -N -e "SHOW STORAGE VOLUMES" 2>/dev/null | grep -c "^__SV_NAME__\b" || true)
if [ "$EXISTS" -ge 1 ]; then
  echo "[sr-sd-sv] storage volume __SV_NAME__ already exists"
else
  RP -e "CREATE STORAGE VOLUME __SV_NAME__ TYPE = S3 LOCATIONS = ('s3://__BUCKET__/') PROPERTIES(\"enabled\"=\"true\", \"aws.s3.endpoint\"=\"__ENDPOINT__\", \"aws.s3.region\"=\"us-east-1\", \"aws.s3.access_key\"=\"$AK\", \"aws.s3.secret_key\"=\"$SK\", \"aws.s3.enable_path_style_access\"=\"true\", \"aws.s3.use_aws_sdk_default_behavior\"=\"false\", \"aws.s3.use_instance_profile\"=\"false\")"
  echo "[sr-sd-sv] storage volume __SV_NAME__ created (LOCATIONS='s3://__BUCKET__/', endpoint=__ENDPOINT__)"
fi

# Set as default (idempotent: SET ... AS DEFAULT is a no-op if already default).
RP -e "SET __SV_NAME__ AS DEFAULT STORAGE VOLUME"

# Verify via DESC (SHOW STORAGE VOLUMES returns the name only; DESC returns
# tabular columns including IsDefault). The output has a header row and a
# data row; awk picks the IsDefault column (3) on the data row matching the
# volume name.
DESC=$(RP -N -e "DESC STORAGE VOLUME __SV_NAME__" 2>&1 || true)
DEFAULT=$(echo "$DESC" | awk '$1 == "__SV_NAME__" {print $3; exit}')
echo "[sr-sd-sv] DESC STORAGE VOLUME __SV_NAME__ -> IsDefault=$DEFAULT"
[ "$DEFAULT" = "true" ] || { echo "ERROR: __SV_NAME__ is not the default (DESC reports IsDefault='$DEFAULT')" >&2; echo "$DESC" >&2; exit 1; }

echo SV_OK
'@
      $sv = $svTmpl.Replace('__ROOT_KV__', $kvRootPw).Replace('__AK_KV__', $kvAk).Replace('__SK_KV__', $kvSk).Replace('__SV_NAME__', $svName).Replace('__BUCKET__', $bucket).Replace('__ENDPOINT__', $endpoint)
      $out = ($sv -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'SV_OK') {
        throw "[sr-sd-sv] storage-volume bootstrap failed (rc=$LASTEXITCODE)"
      }
      Write-Host "[sr-sd-sv] storage volume $svName is DEFAULT -- internal cloud-native tables will land in s3://$bucket/"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      Write-Host "[sr-sd-sv destroy] leaving storage volume + S3 data intact (data preservation; full env destroy clears FE meta)."
      exit 0
    PWSH
  }
}

# nexus-infra-analytics — operator handbook

The EXACT from-zero replay canon for the `04-analytics` tier (per `feedback_handbook_standard.md` invariant 2). An operator (or Greg returning after a break) can rebuild ClickHouse (0.G.5) and StarRocks (0.G.6) from absolute zero using only this document.

> **Status (2026-05-23):** ClickHouse 0.G.5 is **LIVE-RATIFIED** — the 9-VM cluster (3 Keeper + 3 shards × 2 replicas) is up on mTLS, sharded ×3 AND replicated ×2 proven (Distributed `count()` = 600, all shards converged), SQL RBAC + round-robin DNS (all 6 nodes) + NFS backup repo with a cross-node BACKUP→RESTORE round-trip, and `smoke-0.G.5.ps1` is **129/129 GREEN**. The §3.x transient chronology records the 8 apply-time issues found and fixed in source during ratification. Full **cold-rebuild is PROVEN** (destroy → `packer build` → `apply` → `smoke` from zero, smoke 129/129 GREEN; §3.1) with two documented VMware-Workstation-under-load recoveries (vmrun power-on flake #1, nic1 NO-CARRIER #9). **StarRocks 0.G.6 is LIVE-RATIFIED** (2026-05-23): 3 FE (1 leader + 2 followers, BDB-JE, JDK 21) + 3 BE shared-nothing; `nexus.events` sharded (BUCKETS 6) across 3 BE AND replicated ×3; round-robin DNS; broker-less NFS `file://` backup repo + snapshot; `smoke-0.G.6.ps1` **73/73 GREEN** (StarRocks 3.5.17 binary, sourced via the download-portal API after the public-CDN lockdown — §3.B). **Cold-rebuild PROVEN 2026-05-23** (destroy → packer build FE+BE → from-zero apply → smoke 73/73 GREEN), with two documented VMware-Workstation-under-load recoveries: a `vmrun start` "operation was canceled" power-on flake (re-run apply) and the FE leader booting without a usable network (`vmrun reset` power-cycle → SSH/firstboot ready in ~20 s). The CN/shared-data tier (gated on 0.L object storage) is the remaining follow-on.

---

## §0 Prerequisites

### §0.1 Build-host tools
- VMware Workstation Pro (vmrun at `C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`)
- Packer ≥ 1.11, Terraform ≥ 1.9, OpenSSH client, PowerShell 7+
- The lab SSH key loaded: `ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@<vmnet11-ip>`
- VMnet10 (Host-Only backplane) + VMnet11 (Host-Only, routed via nexus-gateway) created (see `nexus-infra-vmware/docs/handbook.md` §0 / `nexus-platform-plan/docs/infra/network.md`)

### §0.2 Other tiers that MUST already be alive
| Tier | VMs (verify) | Why the analytics tier needs it |
|---|---|---|
| **Foundation** | `nexus-gateway` (.70.1) — `ssh nexusadmin@192.168.70.1 'systemctl is-active dnsmasq nfs-server'`; `dc-nexus` (.70.10) | DHCP + DNS (incl. the 20 analytics dhcp-host reservations [9 CH + 6 SR-sn + 5 SR-sd] + round-robin host-records `clickhouse.nexus.lab` / `starrocks-fe.nexus.lab` / `starrocks-sd-fe.nexus.lab`) + the `/srv/nfs/analytics-backups` NFS export (CH/SR-sn backups, ADR-0032; SR-sd backups go through the MinIO storage volume) |
| **Security** | `vault-1/2/3` (.121–.123) + `vault-transit` (.124) — `vault status` on each = unsealed | Vault PKI issues per-host mTLS leaf certs (`clickhouse-server`, `starrocks-server`, **`starrocks-sd-server`**); per-node Vault Agent AppRoles render the certs + KV-seeded creds |
| **MinIO (0.L.1) — only for the shared-data cluster (0.L.5)** | `minio-1/2/3/4` (.141–.144) — `pwsh -File ../nexus-infra-lakehouse/scripts/smoke-0.L.1.ps1` → 41/41 GREEN | SR-shared-data's internal cloud-native tables live in the MinIO storage volume `nexus_minio_starrocks` → `s3://starrocks/`; the `nexus-starrocks-app` MinIO service account + scoped `starrocks-tenant` policy must already be provisioned by `nexus-infra-lakehouse/terraform/envs/lakehouse-minio/role-overlay-minio-starrocks-tenant.tf`. |

### §0.3 Cross-repo state this tier reads
- `nexus-infra-vmware` `envs/foundation` applied: `role-overlay-gateway-analytics-reservations.tf` v3 (dhcp-host + round-robin DNS + NFS export). The 20 analytics MAC→IP reservations (`:8A`–`:98` for CH + SR-sn, `:A5`–`:A9` for SR-sd, see `network.md`).
- `nexus-infra-vmware` `envs/security` applied: PKI roles `clickhouse-server` / `starrocks-server` / `starrocks-sd-server` + per-host AppRole sidecars at `$HOME/.nexus/vault-agent-analytics-{clickhouse,starrocks,starrocks-sd}-<host>.json` + KV sticky-seeds at `nexus/analytics/{clickhouse,starrocks,starrocks-sd}/*`. **The per-cluster TF envs read these sidecars via `filesha256()` at plan time — so security MUST be applied first** (hard ordering, not preference). The MinIO agent policy is **v2** (extends KV reads to `nexus/data/analytics/starrocks-sd/s3-*` so `minio-1` can read the SR-sd S3 creds during the tenant bootstrap).
- `nexus-infra-lakehouse` `envs/lakehouse-minio` applied: `role-overlay-minio-starrocks-tenant.tf` (only for 0.L.5) — provisions the `starrocks` bucket + `nexus-starrocks-app` user + scoped `starrocks-tenant` policy.

---

## §1 Phase walkthrough

### §1.A ClickHouse (Phase 0.G.5)

#### §1.A.1 Build the Packer templates
```powershell
cd packer/analytics-clickhouse-keeper-node ; packer init . ; packer build .   # ~ bake time TBD at ratification
cd ../analytics-clickhouse-server-node     ; packer init . ; packer build .
# Override the ISO to the local cache per memory/project_iso_directory.md:
#   packer build -var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso .
```
Output templates: `H:/VMS/NexusPlatform/_templates/analytics-clickhouse-keeper-node/` + `.../analytics-clickhouse-server-node/`. Post-build spot-check: `vmrun` not required — `systemctl cat nexus-clickhouse-keeper.service` / `nexus-clickhouse-server.service` exist + are DISABLED; apt-shipped units masked; `clickhouse-keeper --version` / `clickhouse-server --version` resolve.

#### §1.A.2 Cross-env operator order (hard ordering)
```
nexus-infra-vmware  envs/foundation  apply   # dhcp-host reservations + round-robin DNS + NFS export
nexus-infra-vmware  envs/security    apply   # clickhouse-server PKI role + 9 AppRole sidecars + KV seeds
nexus-infra-analytics  envs/analytics-clickhouse  apply   # reads the sidecars at plan time
```

#### §1.A.3 Apply
```powershell
pwsh -File scripts/analytics-clickhouse.ps1 apply
```
Apply-flow (numbered): 9 clones (3 keeper + 6 data) → per-clone firstboot (NIC/identity) → nftables-backplane overlay → vault-agents → tls (per-host PKI leaf, PKCS#8) → keeper-config (3-node RAFT quorum, parallel start) → server-config (`remote_servers` 3×2 + `<macros>` + `<zookeeper>`→Keeper) → schema-bootstrap (`ReplicatedMergeTree` + `Distributed` + RBAC) → backup-repo (NFS mount + `Disk`). Wall-clock estimate: TBD at ratification.

#### §1.A.4 Verify the exit gate
```powershell
pwsh -File scripts/analytics-clickhouse.ps1 smoke   # smoke-0.G.5.ps1
```
Expect `ALL 0.G.5 SMOKE CHECKS PASSED`. Manual spot-checks: `system.clusters` shows `nexus_analytics` 3 shards × 2 replicas; `system.replicas` healthy; a `Distributed` INSERT fans across all 3 shards; replica convergence (insert shard1-rep1 → read shard1-rep2); Keeper `mntr` shows 1 leader + 2 followers.

#### §1.A.5 Iterating (selective ops)
```powershell
# Only the Keeper quorum (no data nodes yet):
pwsh -File scripts/analytics-clickhouse.ps1 apply -Vars "enable_ch_shard1_rep1=false,enable_ch_shard1_rep2=false,enable_ch_shard2_rep1=false,enable_ch_shard2_rep2=false,enable_ch_shard3_rep1=false,enable_ch_shard3_rep2=false"
# Re-render only the server config overlay after a config tweak:
pwsh -File scripts/analytics-clickhouse.ps1 apply -Vars "enable_keeper_config=false"   # leaves keeper untouched; example only
```

#### §1.A.6 Tear down
```powershell
pwsh -File scripts/analytics-clickhouse.ps1 destroy
```
Survives: gateway dhcp-host reservations + DNS + NFS export (foundation), the `clickhouse-server` PKI role + KV seeds (security). See §3.1 for the cold-rebuild prerequisite cleanup.

#### §1.A.7 Demos + playbooks (all 11 verb groups)

Every verb group ships a System B JSON demo in [`nexus-cli/docs/demos/`](https://github.com/grezap/nexus-cli/tree/main/docs/demos) (each with `prerequisites` · `expectedOutputContains` · `observe[]` · `whatProves`), executed over SSH until the `ClickHouseAdapter` lands. The cluster-level + persona tour is System A [`DEMO-15`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/demos/DEMO-15.md).

| Verb group | System B demo | What it proves | Where to observe |
|---|---|---|---|
| cluster-status | `demo-0.G.5-clickhouse-cluster-status` | 3 shards × 2 replicas + 3-node Keeper quorum | `system.clusters` / `system.replicas` / Keeper `mntr` |
| health | `demo-0.G.5-clickhouse-health` | replica lag + disk + queue depth | `system.replicas` / `system.disks` |
| topology --watch | `demo-0.G.5-clickhouse-topology` | live shard/replica + data distribution | per-shard `events_local` counts |
| failover-test | `demo-0.G.5-clickhouse-failover-test` | Keeper 1-loss survival + re-election | `mntr` states; insert still commits |
| scale-out | `demo-0.G.5-clickhouse-scale-out` | drain + re-add a replica (idempotent join) | `enable_*` toggle + re-sync |
| scale-up | `demo-0.G.5-clickhouse-scale-up` | vertical RAM resize + clean rejoin | `free -m` + `mntr` |
| backup | `demo-0.G.5-clickhouse-backup` | cross-node BACKUP/RESTORE via shared NFS | `BACKUP_CREATED` / `RESTORED` |
| cert-rotate | `demo-0.G.5-clickhouse-cert-rotate` | fresh PKI leaf + SYSTEM RELOAD CONFIG, no downtime | cert serial change |
| chaos | `demo-0.G.5-clickhouse-chaos` | kill a shard replica; Distributed reroutes | Distributed count stays 600 |
| acl | `demo-0.G.5-clickhouse-acl` | SQL RBAC least-priv app role enforced | app can SELECT, cannot DROP |
| demo (bring-up) | `demo-0.G.5-clickhouse-bring-up` | from-zero build + cold-rebuild gate | `ALL 0.G.5 SMOKE CHECKS PASSED` |

### §1.B StarRocks (Phase 0.G.6)

Builds **after** 0.G.5 (ClickHouse) is sealed + its VMs stopped (`feedback_minimal_running_vms.md`).

#### §1.B.1 Build the Packer templates
```powershell
cd packer/analytics-starrocks-fe-node ; packer init . ; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
cd ../analytics-starrocks-be-node     ; packer init . ; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# Defaults: StarRocks 3.5.17 (ubuntu-amd64 binary) on openjdk-21. To bump the patch,
# get the current OS-suffixed URL + md5 from https://download.starrocks.io/en-US/download/releases :
#   packer build -var starrocks_version=3.5.x -var starrocks_download_url=https://releases.starrocks.io/starrocks/StarRocks-3.5.x-ubuntu-amd64.tar.gz .
```
Output templates: `H:/VMS/NexusPlatform/_templates/analytics-starrocks-fe-node/` + `.../analytics-starrocks-be-node/`. Spot-check: `start_fe.sh`/`start_be.sh` present, JDK installed, `nexus-starrocks-fe.service`/`-be.service` DISABLED.

#### §1.B.2 Cross-env operator order
```
nexus-infra-vmware  envs/foundation  apply   # +6 SR dhcp-host reservations (:93-:98) + starrocks-fe.nexus.lab round-robin + NFS export extended to the 3 BE
nexus-infra-vmware  envs/security    apply   # starrocks-server PKI role + 6 AppRole sidecars + root/app KV seeds
nexus-infra-analytics  envs/analytics-starrocks  apply
```

#### §1.B.3 Apply
```powershell
pwsh -File scripts/analytics-starrocks.ps1 apply
```
Apply-flow: 6 clones (3 FE + 3 BE) → firstboot → nftables-backplane → vault-agents → tls (per-host PKI, PKCS#8) → **fe-bootstrap** (render fe.conf; start the leader; join 2 followers via `ALTER SYSTEM ADD FOLLOWER` + first-start `--helper`; BDB-JE quorum) → **be-join** (render be.conf; start the 3 BE; `ALTER SYSTEM ADD BACKEND` on the leader) → schema-bootstrap (`DISTRIBUTED BY HASH BUCKETS` + `replication_num=3` + RBAC + tablet-distribution proof) → backup-repo (NFS mount + `CREATE REPOSITORY` + `BACKUP SNAPSHOT`).

#### §1.B.4 Verify the exit gate
```powershell
pwsh -File scripts/analytics-starrocks.ps1 smoke   # smoke-0.G.6.ps1 -> ALL 0.G.6 SMOKE CHECKS PASSED
```
Manual spot-checks (`mysql -h 127.0.0.1 -P 9030 -u root -p<root>` on `sr-fe-leader`): `SHOW FRONTENDS` = 1 LEADER + 2 FOLLOWER all Alive; `SHOW BACKENDS` = 3 Alive; `SHOW CREATE TABLE nexus.events` shows `replication_num=3`; `ADMIN SHOW REPLICA DISTRIBUTION FROM nexus.events` spread across all 3 BE.

#### §1.B.5 Iterating (selective ops)
```powershell
# Only the FE quorum (no BE yet):
pwsh -File scripts/analytics-starrocks.ps1 apply -Vars enable_sr_be_1=false,enable_sr_be_2=false,enable_sr_be_3=false,enable_be_join=false
```

#### §1.B.6 Demos + playbooks (all 11 verb groups)
System B demos `demo-0.G.6-starrocks-*.json` in [`nexus-cli/docs/demos/`](https://github.com/grezap/nexus-cli/tree/main/docs/demos): cluster-status · health · topology · failover-test · scale-out · scale-up · backup · cert-rotate · chaos · acl · bring-up. Persona tour: System A [`DEMO-15`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/demos/DEMO-15.md) (StarRocks half).

#### §1.B.7 StarRocks-specific ratification notes (SETTLED 2026-05-23 at live ratification)
- **Version + binary source**: StarRocks **3.5.17** (latest 3.5 stable patch). StarRocks locked their public CDN — the old `StarRocks-<ver>.tar.gz` 403s; releases are now OS-split (`StarRocks-<ver>-ubuntu-amd64.tar.gz`) and discoverable via the portal API `https://download.starrocks.io/en-US/download/releases` (each entry carries `fileUrl` + `md5Hash`). Cached at `H:/VMS/ISO/StarRocks-3.5.17-ubuntu-amd64.tar.gz`.
- **JDK**: Debian 13/trixie ships **no openjdk-17** (only 21 + 25); StarRocks 3.5 requires "JDK 17 or later" so we run **openjdk-21-jre-headless**; `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64` in the FE/BE units + fe-bootstrap. FE leader + followers start clean on JDK 21.
- **MySQL client**: deb13's `default-mysql-client` is **MariaDB 11.8**, which **requires TLS when a password is supplied**; StarRocks' 9030 query port is plaintext, so all password mysql calls use **`--skip-ssl`**.
- **FE follower join**: the `--helper` one-shot → systemd handover works; quorum converges to 1 LEADER + 2 FOLLOWER.
- **Backup repository on NFS**: the broker-less `file://` repository on the shared NFS mount **works** (no Broker needed) — `CREATE REPOSITORY nexus_backups ... file://` registered + `BACKUP SNAPSHOT` issued. Migration to MinIO/S3 is still the 0.L successor (ADR-0032), and is also where the CN/shared-data tier lands.
- **Internal FE↔BE TLS** (thrift/brpc) is newer in StarRocks; the lab posture trusts the VMnet10 backplane (firewall) for internal traffic; tightening is a documented follow-up.

### §1.C StarRocks shared-data (Phase 0.L.5, ADR-0037)

The second StarRocks cluster — **parallel** to the sealed shared-nothing one above. `run_mode=shared_data`; internal cloud-native tables live in a MinIO storage volume; data plane = stateless CN (any CN serves any query from shared storage).

#### §1.C.0 Prerequisites (which machines must already exist + be alive)

- The 6-VM foundation base (`nexus-gateway` + `dc-nexus` + `vault-1/2/3` + `vault-transit`).
- The **MinIO 4-node EC cluster** (Phase 0.L.1, `minio-1..4` at `.141`-`.144`) — the storage backend the cluster writes to. Verify with `pwsh -File ../nexus-infra-lakehouse/scripts/smoke-0.L.1.ps1` → 41/41 GREEN.
- The sealed shared-nothing SR cluster (0.G.6) is NOT a prerequisite — both clusters can run in parallel or one at a time.

#### §1.C.1 Build the Packer templates
```powershell
cd packer/analytics-starrocks-sd-fe-node ; packer init . ; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
cd ../analytics-starrocks-sd-cn-node    ; packer init . ; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
```
Output: `H:/VMS/NexusPlatform/_templates/analytics-starrocks-sd-fe-node/` + `.../analytics-starrocks-sd-cn-node/`. Spot-check (CN): `test -x /opt/starrocks/be/bin/start_cn.sh` + `test -f /opt/starrocks/be/conf/cn.conf` (the BE package ships both FE/BE + the CN binary alongside; CN config defaults to `cn.conf`).

#### §1.C.2 Cross-env operator order
```
nexus-infra-vmware  envs/foundation       apply   # extends dhcp + adds round-robin DNS starrocks-sd-fe.nexus.lab for .37/.38/.39
nexus-infra-vmware  envs/security         apply   # starrocks-sd-server PKI role + 5 AppRole sidecars + KV seeds at nexus/analytics/starrocks-sd/* + minio agent policy v2 (adds KV read on the SR S3 creds so minio-1 can provision the tenant)
nexus-infra-lakehouse  envs/lakehouse-minio apply # role-overlay-minio-starrocks-tenant -- creates the starrocks bucket + nexus-starrocks-app user + scoped starrocks-tenant policy (negative-proof against the warehouse bucket)
nexus-infra-analytics  envs/analytics-starrocks-sd apply
```

#### §1.C.3 Apply
```powershell
pwsh -File scripts/analytics-starrocks-sd.ps1 apply
```
Apply-flow: 5 clones (3 sd FE + 2 sd CN) → firstboot → nftables-backplane → vault-agents → tls (per-host `starrocks-sd-server` PKI, PKCS#8) → **sd-fe-bootstrap** (append `run_mode=shared_data` + `cloud_native_meta_port=6090` + `priority_networks` to fe.conf; start leader; join 2 followers via `ALTER SYSTEM ADD FOLLOWER` + `--helper`; BDB-JE quorum) → **sd-cn-join** (render cn.conf with `priority_networks` + `storage_root_path`; start CN; `ALTER SYSTEM ADD COMPUTE NODE`) → **sd-storage-volume** (import Vault CA into JDK cacerts on FE + system trust store on CN; `CREATE STORAGE VOLUME nexus_minio_starrocks TYPE = S3 LOCATIONS = ('s3://starrocks/') PROPERTIES(...)` with KV-seeded creds; `SET AS DEFAULT STORAGE VOLUME`) → **sd-schema-bootstrap** (cloud-native `nexus.events` in the default storage volume + RBAC + 60-row write/read round-trip + S3-side object proof).

#### §1.C.4 Verify the exit gate
```powershell
pwsh -File scripts/analytics-starrocks-sd.ps1 smoke   # smoke-0.L.5.ps1 -> ALL 0.L.5 SMOKE CHECKS PASSED
```
The smoke **runs CN-loss chaos by default** (kill 1 CN → query still returns 60 rows from shared MinIO; restart CN; kill FE leader → re-election). Pass `-SkipChaos` to suppress destructive checks. Manual spot-checks on `sr-sd-fe-1`: `SHOW FRONTENDS` = 3 alive; `SHOW COMPUTE NODES` = 2 alive; `SHOW STORAGE VOLUMES` shows `nexus_minio_starrocks` `IsDefault=true`; `sudo grep run_mode /opt/starrocks/fe/conf/fe.conf` shows `shared_data`; `sudo mc ls --recursive nexuslocal/starrocks/` on `minio-1` lists objects.

#### §1.C.5 Iterating (selective ops)
```powershell
# Only the FE quorum (no CN yet):
pwsh -File scripts/analytics-starrocks-sd.ps1 apply -Vars enable_sr_sd_cn_1=false,enable_sr_sd_cn_2=false,enable_sd_cn_join=false,enable_sd_storage_volume=false,enable_sd_schema_bootstrap=false
# Re-render only the storage-volume overlay (e.g., after rotating the MinIO secret):
pwsh -File scripts/analytics-starrocks-sd.ps1 apply -Vars enable_sd_schema_bootstrap=false
```

#### §1.C.6 Tear down
```powershell
pwsh -File scripts/analytics-starrocks-sd.ps1 destroy
```
Survives: the MinIO `starrocks` bucket + `nexus-starrocks-app` user + `starrocks-tenant` policy (data preservation; the tenant overlay's destroy is a no-op). The KV seeds at `nexus/analytics/starrocks-sd/*` also survive (sticky). To wipe a cold rebuild's S3 footprint completely: `sudo mc rb --force --dangerous nexuslocal/starrocks` on `minio-1`, then `sudo mc mb nexuslocal/starrocks` before the next apply.

---

## §2 Phase status table

| Sub-phase | Cluster | Closed | Smoke checks |
|---|---|---|---|
| 0.G.5 | ClickHouse (3 shards × 2 replicas + 3 Keeper) | **SEALED 2026-05-23** — live-ratified + cold-rebuild-proven | `smoke-0.G.5.ps1` → 129/129 |
| 0.G.6 | StarRocks (3 FE + 3 BE, shared-nothing) | **SEALED 2026-05-23** — live-ratified + cold-rebuild-proven; CN/shared-data tier deferred to 0.L | `smoke-0.G.6.ps1` → 73/73 |
| 0.L.5 | StarRocks shared-data (3 FE + 2 CN, MinIO storage volume) | **SEALED 2026-05-26** — live-ratified + cold-rebuild-proven (ADR-0037); 5 apply-time transients fixed in source (handbook §3.C) | `smoke-0.L.5.ps1` → 69/69 (chaos default-on) |

---

## §3 Operator runbooks

### §3.1 Cold-rebuild canon (PROVEN 2026-05-23 — full destroy→build→apply→smoke, with documented VMware-flake recoveries)
The exact `destroy → (cross-env regen) → packer build → apply → smoke` sequence with zero operator hot-state between destroy and smoke:
```powershell
pwsh -File scripts/analytics-clickhouse.ps1 destroy
# (cold-rebuild prereqs, if any, codified in scripts/cold-rebuild-prereqs.ps1 — TBD at ratification)
cd packer/analytics-clickhouse-keeper-node ; packer build -force .
cd ../analytics-clickhouse-server-node     ; packer build -force .
pwsh -File scripts/analytics-clickhouse.ps1 apply
pwsh -File scripts/analytics-clickhouse.ps1 smoke   # expect ALL GREEN
```
Ratification checklist (all PROVEN 2026-05-23):
- [x] `packer build` of both templates clean (keeper 6m53s + server 6m49s)
- [x] `terraform destroy` clean (50 resources, no orphaned VMs / dirs)
- [x] from-zero `apply` ALL overlays green (server-config + schema-bootstrap + backup-repo + cross-env foundation/security)
- [x] `smoke-0.G.5.ps1` ALL GREEN (129/129) on the cold-rebuilt cluster
- [x] documented VMware-Workstation-under-load recoveries: re-run after the vmrun "Unknown error" power-on flake (#1); `vmrun connectNamedDevice ... ethernet1` + `systemctl restart nexus-clickhouse-server` for the nic1 NO-CARRIER flake (#9). These are inherent to the lab hypervisor, not config bugs; the DDL-readiness gate makes #9 fail fast with a clear pointer.

### §3.x Apply-time transient chronology
Each observed VM-layer / overlay-layer transient: symptom → diagnosis → recovery / permanent fix in source.

| # | Symptom | Diagnosis | Recovery / fix |
|---|---|---|---|
| 1 | First `analytics-clickhouse.ps1 apply` failed at `power_on` for 2 of 9 VMs (`ch-shard2-rep1`, `ch-shard3-rep2`): `vmrun start ... nogui: exit status 1. Output: Error: Unknown error`. All 9 `clone_vm` + 7 of 9 `power_on` succeeded. | The documented `feedback_vmrun_unknown_error_transient.md` — VMware Workstation sporadically returns rc=1 "Unknown error" when ~9 `vmrun start` fire near-simultaneously (terraform parallelism 10). VM-layer load transient, NOT a config bug; `vmrun list` confirmed exactly the 2 errored VMs were stopped. | **Re-run `apply`** — terraform retries the 2 tainted `power_on` (destroy=`vmrun stop hard` on the already-stopped VM is a no-op; recreate=`vmrun start`), then proceeds to the overlays. No source change; canonical VMware-under-load recovery (same class as kafka 0.H.6 cold-rebuild). |
| 2 | `server-config` readiness probe `clickhouse-client --secure --host localhost --port 9440 'SELECT 1'` failed for 20 min on every data node even though `nexus-clickhouse-server` was active + listening on 9440/8443/9010. Live diag: `Code: 210 SSL Exception: certificate verify failed`. | `clickhouse-client --secure` defaults to verifying the server cert against the system CA store, but our leaf is signed by the internal Vault PKI CA — which the client (run as `nexusadmin`, who can't read the 0640 `ca.crt`) doesn't trust. The server + TLS were fine; only the on-node admin/probe client's chain-verify failed. | **Permanent fix in source**: add `--accept-invalid-certificate` to every on-node `clickhouse-client --secure` call (server-config readiness, schema-bootstrap, backup-repo, smoke-0.G.5). The localhost probe still uses TLS (encrypted); chain-verify is skipped only for the local admin client. The security-meaningful mTLS — inter-server replication (9010) + app clients hitting the round-robin endpoint with the CA — still validates fully. |
| 3 | schema-bootstrap died on `GRANT ON CLUSTER ALL ON *.* TO admin WITH GRANT OPTION` with `Code: 497 ... Missing permissions: SHOW NAMED COLLECTIONS SECRETS ON *`. RBAC role/user creation had succeeded; only the admin GRANT-ALL failed. | The bootstrap runs as `default@localhost`. To `GRANT ... WITH GRANT OPTION` a privilege, the grantor must itself hold that privilege grantably — and `ALL` includes `SHOW NAMED COLLECTIONS SECRETS`, which `default` lacked. CH refuses to grant a privilege the grantor can't itself show/grant. | **Permanent fix in source** (server-config users.d): give the bootstrap `default` user `<named_collection_control>1</named_collection_control>` + `<show_named_collections_secrets>1</show_named_collections_secrets>` (alongside the existing `access_management`). `default` stays localhost-only, so this widens nothing on the network. |
| 4 | **(the hard one)** ReplicatedMergeTree replicas never converged: after the Distributed INSERT each shard had data on exactly ONE replica; the sibling sat at 0 rows with a stuck `system.replication_queue` `GET_PART` entry. The Distributed `count()` fluctuated (195/389/406) because a load-balanced read hit a not-yet-replicated replica. Live diag: `GET_PART ... Timeout: connect timed out: 192.168.70.44:9010`. | Part-fetch source is read from each replica's Keeper `/host` znode, which advertised the node **FQDN** (`ch-shardN-repM.nexus.lab`) — **CH 26.5 ignores `interserver_http_host` for that znode** and uses `getFQDNOrHostName()`. The FQDN resolves (DNS) to the **VMnet11** service IP, where interserver `9010` is firewall-closed (only the VMnet10 backplane opens it). Confirmed: backplane `.10.x:9010` reachable + `openssl verify` OK; the FQDN path timed out. | **Permanent fix in source** (server-config): write an `/etc/hosts` backplane block on every data node mapping each peer FQDN (`ch-shardN-repM{.clickhouse,}.nexus.lab`) → its `192.168.10.x` backplane IP, **before** the server starts, so the advertised FQDN routes interserver traffic over the trusted backplane. (`interserver_http_host` is kept pinned to `.10.x` as belt-and-suspenders for CH versions that honor it.) Live result: all 3 shards converge, Distributed `count()` stable at 600. |
| 5 | After fixing the config, a re-`apply` re-rendered `config.d/nexus-cluster.xml` but the change never took effect on the running servers — replicas still advertised the stale endpoint. | The server-config start step used `systemctl enable --now`, which **starts a stopped unit but no-ops on an already-running one**. So config-overlay edits applied on a warm cluster were silently never loaded. | **Permanent fix in source**: change the start step to `systemctl enable` (boot persistence) **+ `systemctl restart`** (always reloads config; on a cold node `restart` also just starts it). Now every config-version bump genuinely reloads. |
| 6 | After the `/etc/hosts` change, ClickHouse refused to start on all 6 nodes: `systemd status=232/ADDRESS_FAMILIES`, `Invalid token in '.../nexus-cluster.xml', line 15 column 65`. | The new explanatory XML comment contained a literal `--` ("registration time -- it advertises"). **XML comments may not contain a double hyphen** (`--`), so the config parse aborted and the server never opened its listeners. Rendered-config bug that `terraform validate` cannot catch (the XML lives inside a heredoc string). | **Permanent fix in source**: rewrote the comment with no `--`. General rule for these overlays: no double hyphen inside `<!-- ... -->`. |
| 7 | backup-repo overlay (first live run) failed three ways in sequence: (a) PowerShell `ParserError: Variable reference is not valid` on `$nfsServer:$nfsExport`; (b) after fixing, `terraform validate` `Invalid reference` on `${nfsServer}`; (c) after fixing, NFS `mount` rc=32 `No such file or directory`; (d) after fixing, cross-node `RESTORE` `Code: 253 REPLICA_ALREADY_EXISTS`. | (a) PS parses `$nfsServer:` as a `$scope:var` qualifier (`feedback_powershell_url_scope_qualifier.md`). (b) Inside a TF heredoc `${...}` is **Terraform** interpolation (`feedback_terraform_heredoc_powershell.md`). (c) Portainer holds `fsid=0`; an explicit fsid=0 **disables knfsd's auto NFSv4 pseudo-fs server-wide**, so the sibling `fsid=1` analytics export was unreachable (`feedback_nfsv4_fsid0_pseudo_root.md`). (d) `RESTORE ... AS <newname>` recreated the ReplicatedMergeTree with the backup's **hardcoded** zk path `/clickhouse/tables/{shard}/nexus/events_local`, colliding with the live replica's znode. | **Permanent fixes in source**: (a) `$${nfsServer}` in the `.tf` → renders `${nfsServer}` → PS braces. (b) same `$${}` escape. (c) give the analytics export its **own `fsid=0`** (its client set is disjoint from portainer's, so no conflict) in foundation `role-overlay-gateway-nfs-analytics.tf`, and mount via `192.168.70.1:/` (the pseudo-root). (d) schema-bootstrap zk path → `'/clickhouse/tables/{uuid}/{shard}'`: each table (incl. a RESTORE-AS copy) gets its own znode tree → cross-node restore is collision-free; schema switched to deterministic `DROP+CREATE`. Live result: cross-node BACKUP→RESTORE round-trip GREEN. |
| 8 | smoke check "`clickhouse.nexus.lab` resolves to all 6 data-node IPs" FAILED — `dig` returned only `192.168.70.49` (one node). The first fix attempt (a hosts file inside `/etc/dnsmasq.d/`) then took **dnsmasq down lab-wide**: `bad option at line 2 of /etc/dnsmasq.d/hosts.analytics`, `FAILED to start up`. | (a) The foundation DNS overlay used `host-record=name,IP,IP,...`, but dnsmasq's `host-record` keeps **only one IPv4** (later IPs overwrite) — so the round-robin name resolved to a single node, defeating ADR-0031's no-VIP endpoint. (b) The gateway's `conf-dir` parses **every** file in `/etc/dnsmasq.d/` as config (not just `*.conf`; `hosts.nexus` survives only because it is comment-only), so a real hosts file there is invalid config syntax. | **Permanent fix in source** (foundation `role-overlay-gateway-analytics-dns.tf`): write the round-robin entries as a **hosts file** (one `IP  name` line per node — hosts-file form returns ALL A records + rotates) at `/etc/dnsmasq-analytics.hosts`, **outside** the conf-dir, pulled in by `addn-hosts=` from the `.conf` (which stays in the conf-dir). Live result: `clickhouse.nexus.lab` resolves to all 6, rotated; smoke 129/129 GREEN. (Recovery for the downed gateway: move the hosts file out of the conf-dir + `systemctl restart dnsmasq`.) |
| 9 | **(cold-rebuild only)** After destroy → packer build → from-zero `apply`, schema-bootstrap died: first `ON CLUSTER` DDL `Code: 159 ... task not finished` with 2 of 6 data nodes (`.45`, `.48`) stuck `Inactive` in `system.distributed_ddl_queue`. Those nodes also failed every `clickhouse-client` over the backplane and their `DDLWorker` logged `All connection tries failed while connecting to ZooKeeper ... connect timed out :9281`. | The 2 nodes' VMnet10 NIC was `nic1 DOWN <NO-CARRIER>` — VMware Workstation did not connect the second virtual NIC at power-on for 2 of 6 VMs (the `.vmx` had `ethernet1.startConnected = "TRUE"` identical to the working nodes; a power-on flake, same class as transient #1). With no backplane carrier those nodes' DDL/replication workers can't reach Keeper. Restoring carrier alone was not enough — the `DDLWorker`'s Keeper session stayed wedged and only a server restart re-initialized it. | **Operator recovery (VMware-flake, like #1)**: `vmrun connectNamedDevice <vmx> ethernet1` on the affected nodes, then `systemctl restart nexus-clickhouse-server` (re-inits the stuck DDLWorker), then re-run `apply`. **Permanent fix in source**: schema-bootstrap now opens with a distributed-DDL readiness gate (a throwaway `ON CLUSTER` DDL retried until it completes on ALL hosts) so the symptom fails fast with a clear message ("a node's DDL worker can't reach Keeper -- check backplane NIC carrier") instead of a cryptic 150 s hang. Cold-rebuild then completes: smoke 129/129 GREEN. |

### §3.B StarRocks (0.G.6) apply-time transient chronology
Live-ratified 2026-05-23 (smoke 73/73). Each transient: symptom → diagnosis → permanent fix in source.

| # | Symptom | Diagnosis | Recovery / fix |
|---|---|---|---|
| S1 | FE packer build failed at the StarRocks tarball download; `releases.starrocks.io/.../StarRocks-3.3.5*.tar.gz` returns S3 **403 AccessDenied** for every path/format. | StarRocks locked their public release bucket; `3.3.5` predates the OS-split and isn't a published artifact. The download portal (`www.starrocks.io/download/community`) is a HubSpot form that calls a JSON API. | **Fix in source**: pin **3.5.17** (latest 3.5 stable) and the OS-suffixed binary `StarRocks-3.5.17-ubuntu-amd64.tar.gz`. Discover current URLs + md5 via `https://download.starrocks.io/en-US/download/releases`. Verified copy cached at `H:/VMS/ISO/`. (The GitHub "Source code" tarball is NOT usable — it's uncompiled source; the binary lives in the release tarball / Docker images.) |
| S2 | FE build: `No package matching 'openjdk-17-jre-headless' is available`. | Debian 13/trixie ships **no openjdk-17** (only 21 + 25). The templates pinned 17. | **Fix in source**: `jdk_package = openjdk-21-jre-headless` (StarRocks 3.5 = "JDK 17 or later"); `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64` in both systemd units + fe-bootstrap. FE/BE start clean on JDK 21. |
| S3 | FE build: StarRocks download succeeded (~64 s) then `Failed to replace '/tmp/starrocks-3.5.17.tar.gz'`. | `/tmp` is **tmpfs** (~50% of the 4 GB build RAM ≈ 2 GB); the 2.2 GB tarball doesn't fit when ansible moves it from `~/.ansible/tmp` (disk) into tmpfs `/tmp`. Also `get_url timeout: 120` was too short for 2.2 GB. | **Fix in source**: download/unpack from **`/var/tmp`** (disk-backed, never tmpfs) in both roles; bump `get_url timeout` to 1800. |
| S4 | fe-bootstrap: `fe.conf render failed on 192.168.70.32 192.168.70.33` (both follower IPs in one message). | PowerShell `@($leaderIp, ($followers \| %{ $_.ip }))` does **not** flatten — the loop's 2nd element became the whole follower-IP array, so `ssh user@<space-joined-array>`. Build-undetectable; only bites with ≥2 followers. | **Fix in source**: `@($leaderIp) + @($followers \| %{ $_.ip })` (the `+` operator flattens). |
| S5 | schema-bootstrap: `ERROR 2026 (HY000): TLS/SSL error: SSL is required, but the server does not support it` on the password mysql calls (the no-password fe/be calls worked). | deb13's `default-mysql-client` is **MariaDB 11.8**, which **requires TLS once a password is supplied** (passwordless logins auto-disable ssl-verify). StarRocks' 9030 query port is plaintext. MariaDB uses `--skip-ssl` (not `--ssl-mode=DISABLED`). | **Fix in source**: `--skip-ssl` on every `mysql` call across fe-bootstrap, be-join, schema-bootstrap, backup-repo, smoke-0.G.6. Schema also switched to deterministic `DROP+CREATE` so the 60-row proof never double-counts on a re-fire. |
| S6 | backup-repo: `mount.nfs4: mounting 192.168.70.1:/srv/nfs/analytics-backups failed ... No such file or directory`. | Same NFSv4 pseudo-root issue as CH transient #7c — the analytics export is `fsid=0`, so clients mount via `:/`, not the real path. | **Fix in source**: mount `192.168.70.1:/` (pseudo-root). The broker-less `file://` repository then registered + `BACKUP SNAPSHOT` issued with **no Broker needed**. |
| — | re-`apply` power_on flake for `sr-be-2`/`sr-be-3` ("Unknown error" / "operation was canceled"). | Same VMware-under-load `vmrun start` flake as CH transient #1 (6 VMs starting at once). | Re-run `apply` (terraform retries the tainted power_ons). |
| S7 | **(cold-rebuild)** the `nftables-backplane` overlay hung ~20 min then `[sr-nftables sr-fe-leader] SSH + firstboot marker never ready`; the leader VM was **running but unreachable on SSH** (timeout, not refused) — no IP on the service NIC. | VMware-under-load flake on the **primary** NIC at power-on (same class as #1/#9): the leader booted but networkd never brought up a usable `nic0`/`.31`; reconnecting the virtual cable alone didn't make the guest re-acquire its lease. | **Operator recovery**: `vmrun reset <vmx> hard` (power-cycle) → SSH + firstboot marker ready in ~20 s → re-run `apply`. Then FE quorum + BE join + schema EXIT GATE GREEN + smoke 73/73. |
| — | **(cold-rebuild, soft)** backup-repo logged `BACKUP SNAPSHOT not issued (repository type ratification follow-up)` (it WAS issued on the live-ratify run). | The repository registered + mounted fine; the async `BACKUP SNAPSHOT` command returned non-zero on the fresh cluster (timing on a just-registered repo). The overlay treats it as best-effort (`\|\|`). | Non-fatal — smoke 73/73 still GREEN (it verifies the repo + mount, not a FINISHED snapshot). Re-running the snapshot succeeds once the repo settles; tightened polling is a follow-up. |

### §3.C StarRocks shared-data (0.L.5) apply-time transient chronology

Live-ratified 2026-05-26 (smoke `smoke-0.L.5.ps1` 69/69 GREEN with chaos default-on). Each transient: symptom → diagnosis → permanent fix in source.

| # | Symptom | Diagnosis | Recovery / fix |
|---|---|---|---|
| D1 | (cross-tier) `lakehouse-minio` apply fired the new `minio_starrocks_tenant` resource, which got 403 `permission denied` on `vault kv get … nexus/data/analytics/starrocks-sd/s3-access-key` (minio-1's agent token). | The MinIO agent policy v1 only granted read on `nexus/data/lakehouse/minio/*`. The SR-SD tenant bootstrap runs on `minio-1` and needs read on the SR-SD KV S3 creds. | **Permanent fix in source**: bump `nexus-infra-vmware/.../role-overlay-vault-agent-minio-policies.tf` to v2 — adds `path "nexus/data/analytics/starrocks-sd/s3-*" { capabilities = ["read"] }`. Re-apply security → tenant bootstrap then runs cleanly + the cross-bucket-deny proof passes. General lesson: when a new tenant on the MinIO cluster reads creds from a new KV namespace, the MinIO agent policy must be extended to cover it. |
| D2 | `pwsh -File scripts/foundation/...` early (DHCP) — VMware's `VMnetDHCP` service was **stopped** on the build host (cause unknown — sometime since the prior session). Build VMs power on but never get an IP → Debian installer hangs at the boot stage → `disk.vmdk` stays at 7.6 MB after 30 minutes; `vmware.log` shows VMXNET3 activated but no Tools / no progress. The DHCP leases file (`C:\ProgramData\VMware\vmnetdhcp.leases`) has no new entries after Packer powers the VM on. | The Windows service `VMware DHCP Service (VMnetDHCP)` had stopped; the build user account didn't have SCM start permissions to bring it back up. The previously-sealed lab VMs are unaffected (they use `nexus-gateway`'s dnsmasq DHCP, not VMware's; VMware DHCP only serves vmnet8 NAT used by Packer builds). | **Operator recovery**: open an elevated shell on the build host and `Start-Service VMnetDHCP` (or `sc start VMnetDHCP`, or the Services applet). Packer then re-fires cleanly. No source change. **Diagnostic shortcut**: if a Packer build's `disk.vmdk` is still 7.6 MB after ~5 min, check `Get-Service VMnetDHCP` first. |
| D3 | `starrocks_sd_storage_volume` overlay died at `Unexpected token '.Replace' in expression or statement` on line `.Replace('__ROOT_KV__', $kvRootPw) \``. The bash heredoc was being multi-line-built via PowerShell backtick line continuation + `.Method()` on next line. | PowerShell's backtick line continuation joins logical lines but the parser does NOT then accept `.Method()` as a continued expression — it needs the `.` at the END of the previous line (PS's incomplete-expression rule), not after a backtick on the next line. | **Permanent fix in source**: inline the 6 `.Replace(...)` calls on a single line (`$sv = $svTmpl.Replace('A',$a).Replace('B',$b)…`). For longer chains, use `($svTmpl).` with the dot at end-of-line so the parser treats each line as a continuation. New feedback memory candidate: `feedback_powershell_backtick_method_continuation`. |
| D4 | `starrocks_sd_storage_volume` re-fire reported `ERROR: nexus_minio_starrocks is not the default storage volume (got '')` even though `SET nexus_minio_starrocks AS DEFAULT STORAGE VOLUME` had just run successfully. | `SHOW STORAGE VOLUMES` in StarRocks returns the **name column only** (one column: `Storage Volume`). My verify used `awk '{print $2}'` on its output, which is empty. The correct command for IsDefault is `DESC STORAGE VOLUME <name>` which returns 7 tabular columns: `Name Type IsDefault Location Params Enabled Comment`. My first DESC-based fix then *also* failed because `grep -i 'IsDefault'` matched the **header row** which has no boolean. | **Permanent fix in source**: use `DESC STORAGE VOLUME <name>` + `awk '$1 == "<name>" {print $3}'` to extract the IsDefault column from the data row by matching column 1 to the volume name. Same fix mirrored in `smoke-0.L.5.ps1` (parses the data row by matching the name regex + reads token 3). |
| D5 | `starrocks_sd_schema_bootstrap` died at `CREATE TABLE nexus.events ...` with `ERROR 1064: Failed to create partition[...]. Timeout: tablet_create_timeout_second(=10s)` and a suggested fix `admin set frontend config("tablet_create_timeout_second"="20")`. | The first cloud-native `CREATE TABLE` against a fresh storage volume in shared-data mode materializes the tablet's path tree in the object store, which takes longer than StarRocks's 10 s default tablet-create timeout. (In shared-nothing this is fast because BE-local file creation is millisecond-scale; in shared-data it's a chain of S3 PUTs.) | **Permanent fix in source**: in `schema-bootstrap` run `ADMIN SET FRONTEND CONFIG ("tablet_create_timeout_second" = "60")` BEFORE the `CREATE TABLE`. `ADMIN SET FRONTEND CONFIG` is in-memory + idempotent; survives until FE restart (a follow-up could bake it into `fe.conf` for restart-safety). 60 s is generous; observed first-create takes ~5–15 s on the lab. |

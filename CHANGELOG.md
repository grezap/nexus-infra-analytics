# Changelog

All notable changes to `nexus-infra-analytics` are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-26 — pending tag

### Phase 0.L.5 SEALED — StarRocks shared-data tier live-ratified + cold-rebuild-proven (ADR-0037)

Second StarRocks cluster added to the repo (parallel to the sealed shared-nothing 0.G.6 one), live + cold-rebuild-proven on the per-engine + per-cluster-state canon. `smoke-0.L.5.ps1` **69/69 GREEN** with chaos default-on — CN-loss tolerance (kill a CN → query still returns 60 rows from shared MinIO storage; the headline shared-data HA property) + FE-leader re-election proven on every run. 5 apply-time transients diagnosed + fixed in source (handbook §3.C):

- D1 — MinIO agent KV policy gap for new tenants (v1 → v2 adds read on `nexus/data/analytics/starrocks-sd/s3-*`).
- D2 — `VMnetDHCP` Windows service was stopped on the build host; build VMs hung at install. Operator recovery: elevated `Start-Service VMnetDHCP`.
- D3 — PowerShell backtick line-continuation + `.Method()` on next line = ParserError. Fix: inline the `.Replace()` chain on one line.
- D4 — `SHOW STORAGE VOLUMES` returns name-only (no `IsDefault` column); use `DESC STORAGE VOLUME <name>` + `awk` on the data row.
- D5 — StarRocks shared-data first cloud-native `CREATE TABLE` against a fresh storage volume hits `tablet_create_timeout_second=10s` (S3 PUT chain takes longer than local). Fix: `ADMIN SET FRONTEND CONFIG ("tablet_create_timeout_second" = "60")` before CREATE TABLE.

### Added — Phase 0.L.5 — StarRocks shared-data tier scaffolded (2026-05-26, ADR-0037)

Adds the **second StarRocks cluster** to the repo (parallel to the sealed shared-nothing 0.G.6 one). Storage-compute-separation deployment: 3 FE BDB-JE quorum + 2 stateless **Compute Nodes**; internal cloud-native tables in a MinIO **storage volume** (`s3://starrocks/`) backed by the 0.L.1 4-node EC cluster. Tier 04-analytics now hosts 20 VMs (15 → 20).

**Two new per-engine Packer templates** (full isolation from the sealed cluster's templates per the per-engine-template canon): `packer/analytics-starrocks-sd-fe-node/` (StarRocks FE 3.5.17 + JDK 21; `nexus-starrocks-sd-fe.service` DISABLED) + `packer/analytics-starrocks-sd-cn-node/` (StarRocks BE package — same tarball — started via `be/bin/start_cn.sh` with `cn.conf`; `nexus-starrocks-sd-cn.service` DISABLED). The shared `_shared/analytics_firstboot` script gets 5 additional IP→role cases (`.37`/`.38`/`.39` → `starrocks-sd-fe`; `.30`/`.40` → `starrocks-sd-cn`; cluster `starrocks-sd`).

**Per-cluster Terraform env** `terraform/envs/analytics-starrocks-sd/` (5 `module.vm`: 3 FE + 2 CN; overlays: nftables-backplane, vault-agents [sidecars `vault-agent-analytics-starrocks-sd-<host>.json`], tls [PKI role `starrocks-sd-server`, PKCS#8, SAN `starrocks-sd-fe.nexus.lab`], **sd-fe-bootstrap** [fe.conf with `run_mode=shared_data` + `cloud_native_meta_port=6090` + priority_networks; leader-first + 2 followers via `ALTER SYSTEM ADD FOLLOWER` + `--helper`], **sd-cn-join** [cn.conf with priority_networks + storage_root_path; `ALTER SYSTEM ADD COMPUTE NODE`], **sd-storage-volume** [import Vault CA into FE JDK cacerts + CN system trust store; `CREATE STORAGE VOLUME nexus_minio_starrocks TYPE = S3 ...` + `SET AS DEFAULT STORAGE VOLUME`], **sd-schema-bootstrap** [cloud-native `nexus.events` in the default storage volume + RBAC + 60-row write/read round-trip + S3-side object proof]). Cluster S3 credentials read on-node from Vault KV via the per-host agent token; never embedded in `fe.conf`.

**Operator surface**: `scripts/analytics-starrocks-sd.ps1` + `scripts/smoke-0.L.5.ps1` (**runs CN-loss chaos by default** — kill 1 CN, prove the query still returns 60 rows from shared MinIO storage; plus FE-leader re-election; `-SkipChaos` to suppress).

**Cross-tier (nexus-infra-vmware)**: `foundation` reservations overlay bumped v2 → v3 (adds 5 SR-SD dhcp-host `:A5`-`:A9` → `.37`/`.38`/`.39`/`.30`/`.40`) + analytics DNS overlay bumped v2 → v3 (adds round-robin `starrocks-sd-fe.nexus.lab` → 3 FE); `security` adds the `starrocks-sd-server` PKI role + 5 narrow agent policies + 5 AppRoles/sidecars + 4 KV creds at `nexus/analytics/starrocks-sd/{root-password,app-password,s3-access-key,s3-secret-key}`. The MinIO agent policy is bumped v1 → v2 (adds KV read on `nexus/data/analytics/starrocks-sd/s3-*` so minio-1 can provision the tenant). **Cross-tier (nexus-infra-lakehouse)**: new `role-overlay-minio-starrocks-tenant.tf` in `terraform/envs/lakehouse-minio/` provisions the dedicated MinIO tenant (bucket `starrocks` + service account `nexus-starrocks-app` + scoped `starrocks-tenant` policy; cross-bucket-deny proven via a `mc cp` to `s3://warehouse` that must fail).

**Canon**: ADR-0037 (amends ADR-0030); MASTER-PLAN 0.L row updated; vms.yaml `vm_count: 88 → 93` (cluster `starrocks-sd` added); network.md DNS + MAC table extended; glossary adds "Shared-data mode", "Compute Node", "Storage volume" entries; handbook §1.C walkthrough + §2 status row.

**Pending**: live ratification + cold-rebuild proof; §3.C transient chronology; `v0.2.0` tag.

---

## [0.1.0] - 2026-05-23

### Phase 0.G analytics tier SEALED — ClickHouse (0.G.5) + StarRocks (0.G.6) live-ratified + cold-rebuild-proven

Both analytics clusters are live on the NexusPlatform VMware lab (88 VMs built through Phase 0.L.4), each rebuilt from zero (destroy → `packer build` → from-zero `apply` → smoke) with **no toy databases** — sharding AND replication proven in the smoke gates.

- **0.G.5 ClickHouse — SEALED.** 3 ClickHouse Keeper (RAFT quorum, NOT ZooKeeper) + 3 shards × 2 replicas on per-host Vault PKI mTLS. `nexus.events` Distributed over ReplicatedMergeTree: sharded ×3 AND replicated ×2 (Distributed `count()` = 600, all shards converged); SQL RBAC; round-robin DNS (`clickhouse.nexus.lab` → all 6, no VIP); NFS backup repo with a cross-node BACKUP→RESTORE round-trip. **`smoke-0.G.5.ps1` 129/129 GREEN**, cold-rebuild proven.
- **0.G.6 StarRocks — SEALED (shared-nothing).** 3 FE (1 leader + 2 followers, BDB-JE quorum, `--helper` join) + 3 BE on **JDK 21**, StarRocks **3.5.17**. `nexus.events` `DISTRIBUTED BY HASH BUCKETS 6` × `replication_num=3` — sharded across 3 BE AND replicated ×3; SQL RBAC; round-robin DNS (`starrocks-fe.nexus.lab`); broker-less NFS `file://` backup repo. **`smoke-0.G.6.ps1` 73/73 GREEN**, cold-rebuild proven. The CN / shared-data (storage-compute-separation) tier is deferred to Phase 0.L (object storage).
- **Ratification transients** (15 total) diagnosed + fixed in source and chronicled in `docs/handbook.md` §3.x (ClickHouse #1–#9) + §3.B (StarRocks S1–S7): incl. ReplicatedMergeTree interserver part-fetch over the backplane (`/etc/hosts`), config-overlay restart, NFSv4 `fsid=0` pseudo-root mount, dnsmasq round-robin via `addn-hosts`, ClickHouse zk path `{uuid}`, distributed-DDL readiness gate; StarRocks public-CDN lockdown (3.5.17 via the download-portal API), deb13 openjdk-21, `/var/tmp` for the 2.2 GB tarball, MariaDB `--skip-ssl`, plus VMware-under-load power-on / NIC-carrier recoveries.

### Added — Phase 0.G.6 — StarRocks (3 FE BDB-JE quorum + 3 BE) scaffolded (2026-05-22)

Adds the second analytics cluster on the same per-engine/per-cluster canon.

**2 per-engine Packer templates**: `packer/analytics-starrocks-fe-node/` + `packer/analytics-starrocks-be-node/` (Debian 13 + JDK 17 + StarRocks 3.3.x from the release tarball; `nexus-starrocks-fe.service` / `-be.service` DISABLED; FE node also bakes `default-mysql-client`). RAM right-sized (FE 8→4 GB, BE 16→6 GB; logged in `vms.yaml`).

**Per-cluster Terraform env** `terraform/envs/analytics-starrocks/` (6 `module.vm`: 3 FE + 3 BE; overlays: nftables-backplane, vault-agents, tls, **fe-bootstrap** [leader-first + 2 followers via `ALTER SYSTEM ADD FOLLOWER` + `--helper`; BDB-JE quorum], **be-join** [`ALTER SYSTEM ADD BACKEND`], schema-bootstrap [`DISTRIBUTED BY HASH BUCKETS` + `replication_num=3` + RBAC + tablet-distribution proof], backup-repo [NFS + `CREATE REPOSITORY` + `BACKUP SNAPSHOT`]). `terraform validate` clean.

**Operator surface**: `scripts/analytics-starrocks.ps1` + `scripts/smoke-0.G.6.ps1`.

**Cross-tier (nexus-infra-vmware)**: foundation reservations overlay v2 (+6 StarRocks dhcp-host `:93`–`:98` → `.31`–`.36`) + round-robin `starrocks-fe.nexus.lab` (3 FE) + NFS export extended to the FE/BE; security overlay (`starrocks-server` PKI role + 6 AppRoles/policies/sidecars + root/app KV sticky-seeds).

**Demos**: 11 System B JSONs (`demo-0.G.6-starrocks-*.json`) covering all verb groups; System A `DEMO-15` StarRocks half.

**StarRocks-specific ratification notes** (handbook §1.B.7): JAVA_HOME path, FE `--helper`→systemd handover, NFS-repository-needs-broker (MinIO/S3 migration at 0.L), internal FE↔BE TLS posture.

CI matrix extended (4 packer templates + 2 terraform envs). Live-ratify + cold-rebuild proof + `v0.1.0` tag pending (operator-owned).

### Added — Phase 0.G.5 — ClickHouse (3 shards × 2 replicas + 3-node Keeper quorum) scaffolded (2026-05-22)

Bootstraps the `nexus-infra-analytics` repo (tier `04-analytics`) and the first analytics cluster, on the per-cluster Terraform state + per-engine Packer template architectural canon (`feedback_per_cluster_state_per_engine_template.md`) from day one.

**Repo scaffold** (mirrors `nexus-infra-kafka` / `nexus-infra-oltp`): README, CHANGELOG, LICENSE (MIT), `ansible.cfg`, `.gitignore`, `.github/workflows/packer-validate.yml` (packer + terraform matrices + ansible-lint + shell-lint + gitleaks), `terraform/modules/vm` (copied), `scripts/configure-vm-nic.ps1` (copied), and the 4 shared Ansible roles (`nexus_identity`, `nexus_network`, `nexus_firewall`, `nexus_observability`) + a new `analytics_firstboot` role.

**`analytics_firstboot` shared role**: `analytics-node-firstboot.sh` does NIC discovery (MAC OUI byte 5: 0x00 primary VMnet11, 0x01 secondary VMnet10), nic0/nic1 rename, hostname + `/etc/hosts`, VMnet10 backplane `.link` MAC-match + static `.network`, and writes `node-identity.env` for the Terraform overlays. The IP→role map covers both analytics clusters (ClickHouse `.41`–`.49`, StarRocks `.31`–`.36`); for ClickHouse server nodes it parses `{shard}`/`{replica}` from the hostname (`ch-shardN-repM`) and emits `NEXUS_CH_SHARD`/`NEXUS_CH_REPLICA` so the server-config overlay renders `<macros>` per-node ([ADR-0029](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0029-clickhouse-shard-replica-topology.md)).

**2 per-engine Packer templates**:

- `packer/analytics-clickhouse-keeper-node/`: Debian 13 + ClickHouse `clickhouse-keeper` from the ClickHouse vendor apt repo. `nexus-clickhouse-keeper.service` delivered DISABLED; apt-shipped unit masked. ~2 GB RAM (right-sized from canon 4 GB).
- `packer/analytics-clickhouse-server-node/`: Debian 13 + `clickhouse-server` + `clickhouse-client` from the vendor apt repo. `nexus-clickhouse-server.service` DISABLED; apt-shipped unit masked. ~6 GB RAM (right-sized from canon 16 GB).

**Per-cluster Terraform env** `terraform/envs/analytics-clickhouse/` (9 `module.vm` blocks: 3 keeper + 6 data; overlays: nftables-backplane, vault-agents, tls, keeper-config, server-config, schema-bootstrap, backup-repo). All `enable_*` toggles default `true` (`feedback_terraform_partial_apply_destroys_resources.md`).

**Operator surface**: `scripts/analytics-clickhouse.ps1` (`apply | destroy | smoke | cycle | plan | validate`) + `scripts/smoke-0.G.5.ps1`.

**Cross-tier (in `nexus-infra-vmware`)**: foundation overlay (15 analytics dhcp-host reservations `:8A`–`:98` + round-robin `clickhouse.nexus.lab` host-record + `/srv/nfs/analytics-backups` NFS export) + security overlay (`clickhouse-server` PKI role + 9 AppRoles/policies/sidecars + KV sticky-seeds).

**Cross-tier canon** (per `feedback_canon_docs_continuous_update.md`): ADRs 0028–0032 in `nexus-platform-plan`; `vms.yaml` RAM right-sized (keeper 4→2 GB, data 16→6 GB) + sub-phase pinned; MASTER-PLAN 0.G.5/0.G.6 rows; `network.md` round-robin DNS + analytics MAC block + no-VIP note; `glossary.md` extended (ClickHouse / Keeper / ReplicatedMergeTree / Distributed / Shard·Replica / StarRocks / FE·BE / Tablet).

RAM right-sized per `feedback_prefer_less_memory.md` (build host 256 GB; deviations logged in `vms.yaml`); production sizing reverts to canon.

### Demos
System B JSON demos (`demo-0.G.5-*.json`, 11 verb groups) + System A analytics persona tour authored in `nexus-cli` / `nexus-platform-plan` (executed via the smoke gate / SSH until the `ClickHouseAdapter` lands in the later unified CLI phase).

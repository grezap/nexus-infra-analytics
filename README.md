# nexus-infra-analytics

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.G.5%20%2B%200.G.6%20%2B%200.L.5%20SEALED-brightgreen)](./CHANGELOG.md)
[![Release](https://img.shields.io/badge/release-v0.2.0-blue)](./CHANGELOG.md)

Analytics data tier of the **NexusPlatform lab** (93 VMs built/cold-rebuild-proven through Phase 0.L.5) — ClickHouse (Keeper quorum + sharded/replicated MergeTree) · StarRocks **shared-nothing** (FE quorum + BE tablet sharding) · StarRocks **shared-data** (FE quorum + stateless CN, MinIO storage volume). 20 VMs on tier `04-analytics`.

> **Canon:** This repo implements [Phases 0.G.5 + 0.G.6 + 0.L.5](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) of the NexusPlatform blueprint. VM inventory is [`nexus-platform-plan/docs/infra/vms.yaml`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/vms.yaml) (cluster `clickhouse` + cluster `starrocks` + cluster `starrocks-sd`). Architectural source of truth is [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan). Tool glossary: [`docs/glossary.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/glossary.md).
>
> **➜ Want to rebuild the analytics tier from zero?** [`docs/handbook.md`](./docs/handbook.md) is the operator canon (EXACT from-zero replay per `feedback_handbook_standard.md` invariant 2).
>
> **Phase 0.G analytics tier SEALED (2026-05-23, `v0.1.0`):** both 0.G clusters are **live-ratified + cold-rebuild-proven** on the per-cluster + per-engine architectural canon (`feedback_per_cluster_state_per_engine_template.md`). ClickHouse `smoke-0.G.5.ps1` **129/129 GREEN**; StarRocks (shared-nothing) `smoke-0.G.6.ps1` **73/73 GREEN** (StarRocks 3.5.17, JDK 21). 15 apply-time transients diagnosed + fixed in source ([handbook §3.x + §3.B](./docs/handbook.md)).
>
> **Phase 0.L.5 StarRocks shared-data SEALED (2026-05-26):** the repo now also hosts the **second StarRocks cluster** (parallel to the sealed shared-nothing one) — 3 FE BDB-JE quorum (`sr-sd-fe-1/2/3` at `.37`/`.38`/`.39`) + 2 stateless CN (`sr-sd-cn-1` at `.30`, `sr-sd-cn-2` at `.40` — documented decade-spill) on `run_mode=shared_data`. Internal cloud-native tables live in a MinIO storage volume `nexus_minio_starrocks` → `s3://starrocks/`; dedicated `nexus-starrocks-app` MinIO service account with a scoped `starrocks-tenant` policy ([ADR-0037](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0037-starrocks-shared-data-cn-minio-storage-volume.md) amends ADR-0030). Live-ratified + **cold-rebuild proven** (`smoke-0.L.5.ps1` **69/69 GREEN** with chaos default-on: CN-loss + FE-leader re-election; 5 apply-time transients fixed in source — handbook §3.C). **Tagged `v0.2.0` 2026-05-26** as part of the 0.L close-out.

## Architecture at a glance

Both stores are genuine multi-node clusters that are **sharded AND replicated** (the MASTER-PLAN "no toy databases" mandate, proven in the smoke gate — not assumed):

| Cluster | Sub-phase | Topology | Coordination | Sharding | Replication |
|---|---|---|---|---|---|
| **ClickHouse** | 0.G.5 | 3 shards × 2 replicas (6 data) + 3 Keeper | **ClickHouse Keeper** (C++ RAFT, not ZooKeeper — [ADR-0028](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0028-clickhouse-keeper-not-zookeeper.md)) | `Distributed` over 3 shards | `ReplicatedMergeTree` ×2/shard ([ADR-0029](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0029-clickhouse-shard-replica-topology.md)) |
| **StarRocks** | 0.G.6 | 3 FE (BDB-JE quorum) + 3 BE | FE Leader + 2 Followers (majority) | tablets `DISTRIBUTED BY HASH BUCKETS n` across 3 BE | `replication_num=3` ([ADR-0030](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0030-starrocks-fe-quorum-be-tablet-sharding.md)) |

**Client front door = round-robin DNS, no VRRP VIP** (`clickhouse.nexus.lab` / `starrocks-fe.nexus.lab`). Both engines are natively any-node-addressable, so there is no fixed-endpoint SPOF a VIP would remove — the documented "client-side multi-endpoint" branch of [ADR-0025](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0025-ha-promise-covers-lb-tier.md), resolved for the analytics tier in [ADR-0031](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0031-analytics-client-front-door-round-robin-dns.md).

**Backup repository = NFS export from `nexus-gateway`** (`/srv/nfs/analytics-backups`); MinIO/S3 deferred to Phase 0.L ([ADR-0032](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0032-analytics-backup-repository-nfs-gateway.md)).

## Status

| Sub-phase | Cluster | VMs | nexus-cli release | Status |
|---|---|---|---|---|
| 0.G.5 | ClickHouse (3 shards × 2 replicas + 3 Keeper) | 9 | ClickHouseAdapter (later unified CLI phase) | **SEALED 2026-05-23** — live-ratified + cold-rebuild-proven; `smoke-0.G.5.ps1` **129/129** |
| 0.G.6 | StarRocks (3 FE + 3 BE, shared-nothing) | 6 | StarRocksAdapter (later unified CLI phase) | **SEALED 2026-05-23** — live-ratified + cold-rebuild-proven (StarRocks 3.5.17, JDK 21); `smoke-0.G.6.ps1` **73/73**; CN/shared-data tier deferred to 0.L |

The `nexus-cli` `ClickHouseAdapter` + `StarRocksAdapter` ship in the later unified CLI adapter phase (covering all 7 data clusters at once); they shell out over SSH to on-node `clickhouse-client` / `mysql` (StarRocks speaks the MySQL protocol) — no managed DB driver linked into the AOT binary, ≤30 MB ([ADR-0024](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0024-aot-gate-amendment-and-cluster-adapter-framework.md)). The System B demos for all 11 verb groups are authored now (in [`nexus-cli/docs/demos/`](https://github.com/grezap/nexus-cli/tree/main/docs/demos)) and executed via the smoke gate / SSH until the adapters land.

## Cross-tier prerequisites

The analytics tier consumes state from earlier-phase tiers (exact dependency chain with hostnames + IPs + how to verify each is alive is in [`docs/handbook.md` §0](./docs/handbook.md)):

- **Foundation tier alive** — `nexus-gateway` (dnsmasq DHCP + DNS + the 15 analytics dhcp-host MAC reservations + round-robin `host-record`s + the `/srv/nfs/analytics-backups` NFS export) + `dc-nexus`. Managed in [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) (`envs/foundation`).
- **Security tier alive** — 3-node Vault HA + `vault-transit` auto-unseal + PKI hierarchy. Per-cluster PKI roles (`clickhouse-server`, `starrocks-server`) issue 90-day leaf certs for mTLS; per-node Vault Agent AppRoles render the certs + KV-seeded creds. Managed in [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) (`envs/security`).

## Cluster verbs (nexus-cli surface)

Every cluster in this repo gets the 11 data-cluster verb groups via [`grezap/nexus-cli`](https://github.com/grezap/nexus-cli) (`IClusterAdapter` SPI):

| Verb group | Purpose |
|---|---|
| `cluster-status` | live introspection (`system.clusters`/`system.replicas`; `SHOW FRONTENDS`/`BACKENDS`) |
| `failover-test` | drive a failover scenario + measure RTO (Keeper-loss; FE-leader-loss; BE-loss) |
| **`scale-out`** add/remove | cluster-membership change — add a CH replica/shard; `ALTER SYSTEM ADD BACKEND`/`ADD FOLLOWER` |
| **`scale-up`** | vertical VM resize (CPU/RAM/disk) — cluster-aware |
| `backup` take/restore | `BACKUP/RESTORE` (CH) · `BACKUP/RESTORE SNAPSHOT` (SR) to the NFS repository |
| `health` | rich healthcheck (replica lag, tablet skew, disk usage) |
| `topology --watch` | live shard/replica + tablet map |
| `cert-rotate` | trigger Vault Agent re-render + service reload |
| `chaos` | injection (kill a shard replica / Keeper / FE leader / BE) |
| `acl` | SQL-driven RBAC (`CREATE USER/ROLE/GRANT`) |
| `demo` | run a System B demo against this cluster |

## Quick links

- **Operator handbook:** [`docs/handbook.md`](./docs/handbook.md)
- **Per-sub-phase verification:** [`docs/verification/`](./docs/verification/) (populated as smoke gates pass)
- **Architectural decisions:** cross-tier ADRs 0028–0032 in [`nexus-platform-plan/docs/adr/`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/index.md); repo-local ADRs in [`docs/adr/`](./docs/adr/)
- **Cross-tier setup index:** [`nexus-platform-plan/docs/setup-guides.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/setup-guides.md)

## License

[MIT](./LICENSE) © 2026 Greg Zapantis

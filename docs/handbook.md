# nexus-infra-analytics — operator handbook

The EXACT from-zero replay canon for the `04-analytics` tier (per `feedback_handbook_standard.md` invariant 2). An operator (or Greg returning after a break) can rebuild ClickHouse (0.G.5) and StarRocks (0.G.6) from absolute zero using only this document.

> **Status (2026-05-22):** §1 ClickHouse walkthrough populated at scaffold; §3.1 cold-rebuild canon is **aspirational** until the operator runs the live `packer build` + `apply` + `smoke` cycle and ratifies it (the transient chronology in §3.x is the recording of that proof). StarRocks (0.G.6) §1.B fills in when that sub-phase lands.

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
| **Foundation** | `nexus-gateway` (.70.1) — `ssh nexusadmin@192.168.70.1 'systemctl is-active dnsmasq nfs-server'`; `dc-nexus` (.70.10) | DHCP + DNS (incl. the 15 analytics dhcp-host reservations + round-robin `clickhouse.nexus.lab` host-record) + the `/srv/nfs/analytics-backups` NFS export (the backup repository, ADR-0032) |
| **Security** | `vault-1/2/3` (.121–.123) + `vault-transit` (.124) — `vault status` on each = unsealed | Vault PKI issues per-host mTLS leaf certs (`clickhouse-server` role); per-node Vault Agent AppRoles render the certs + KV-seeded creds |

### §0.3 Cross-repo state this tier reads
- `nexus-infra-vmware` `envs/foundation` applied: `role-overlay-gateway-analytics-reservations.tf` (dhcp-host + round-robin DNS + NFS export). The 15 analytics MAC→IP reservations (`:8A`–`:98`, see `network.md`).
- `nexus-infra-vmware` `envs/security` applied: `role-overlay-vault-pki-clickhouse.tf` (PKI role `clickhouse-server`) + 9 per-host AppRole sidecars at `$HOME/.nexus/vault-agent-analytics-clickhouse-<host>.json` + KV sticky-seeds at `nexus/analytics/clickhouse/*`. **The `envs/analytics-clickhouse` plan reads these sidecars via `filesha256()` at plan time — so security MUST be applied first** (hard ordering, not preference).

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
*(fills in when 0.G.6 lands — analytics-starrocks-fe-node + analytics-starrocks-be-node templates + `envs/analytics-starrocks/`.)*

---

## §2 Phase status table

| Sub-phase | Cluster | Closed | Smoke checks |
|---|---|---|---|
| 0.G.5 | ClickHouse (3 shards × 2 replicas + 3 Keeper) | scaffolded 2026-05-22; live-ratify pending | `smoke-0.G.5.ps1` |
| 0.G.6 | StarRocks (3 FE + 3 BE) | planned | `smoke-0.G.6.ps1` |

---

## §3 Operator runbooks

### §3.1 Cold-rebuild canon (ASPIRATIONAL until ratified)
The exact `destroy → (cross-env regen) → packer build → apply → smoke` sequence with zero operator hot-state between destroy and smoke:
```powershell
pwsh -File scripts/analytics-clickhouse.ps1 destroy
# (cold-rebuild prereqs, if any, codified in scripts/cold-rebuild-prereqs.ps1 — TBD at ratification)
cd packer/analytics-clickhouse-keeper-node ; packer build -force .
cd ../analytics-clickhouse-server-node     ; packer build -force .
pwsh -File scripts/analytics-clickhouse.ps1 apply
pwsh -File scripts/analytics-clickhouse.ps1 smoke   # expect ALL GREEN
```
Ratification checklist (flip to PROVEN when all checked):
- [ ] `terraform destroy` clean (no orphaned VMs / dirs)
- [ ] `packer build` of both templates clean
- [ ] from-zero `apply` ALL overlays green
- [ ] `smoke-0.G.5.ps1` ALL GREEN with no operator hot-state

### §3.x Apply-time transient chronology
*(each observed VM-layer / overlay-layer transient gets a row here at live ratification: symptom → diagnosis → recovery / permanent fix in source.)*

| # | Symptom | Diagnosis | Permanent fix |
|---|---|---|---|
| — | *(none yet — fills in at live ratification)* | | |

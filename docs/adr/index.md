# Architecture Decision Records — `nexus-infra-analytics`

> Numbering is local to this repo (independent of the parent `nexus-platform-plan`
> ADRs and the sibling `nexus-cli` ADRs). Format follows
> [Michael Nygard's classic template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

> **Cross-tier canon:** the load-bearing analytics-tier decisions span repos and live
> in [`nexus-platform-plan/docs/adr/`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/index.md):
> - **ADR-0028** — ClickHouse Keeper, not ZooKeeper, for replication coordination
> - **ADR-0029** — ClickHouse topology: 3 shards × 2 replicas, Distributed over ReplicatedMergeTree
> - **ADR-0030** — StarRocks topology: FE quorum (BDB-JE) + BE tablet sharding/replication
> - **ADR-0031** — Analytics client front door: round-robin DNS, no VRRP VIP (resolves ADR-0025)
> - **ADR-0032** — Analytics backup repository: NFS export from nexus-gateway (MinIO deferred to 0.L)
>
> Implementation-level decisions for the `nexus-cli` adapters live in
> [`nexus-cli/docs/adr/`](https://github.com/grezap/nexus-cli/blob/main/docs/adr/index.md).

| ID | Status | Title |
|---:|:---:|---|
| — | — | *(none yet — repo-local ADRs land if a decision is specific to this repo's implementation and not already covered by the cross-tier ADRs 0028–0032 above)* |

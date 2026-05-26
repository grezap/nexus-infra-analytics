#!/bin/bash
# analytics-node-firstboot.sh -- runs once at first boot per analytics-node clone.
#
# Linear port of oltp-node-firstboot.sh (nexus-infra-oltp), scaled to the
# 04-analytics tier. Same NIC discrimination by MAC OUI byte 5 (0x00 primary
# VMnet11, 0x01 secondary VMnet10), same /etc/hosts pattern, same hostname
# renaming, same VMnet10 backplane .link MAC-match.
#
# IP-to-role map covers ALL THREE analytics clusters:
#   - 0.G.5 ClickHouse:        3 Keeper (.41-.43) + 3 shards x 2 replicas (.44-.49)
#   - 0.G.6 StarRocks sn:      3 FE (.31-.33) + 3 BE (.34-.36)
#   - 0.L.5 StarRocks sd:      3 FE (.37-.39) + 2 CN (.30,.40) -- ADR-0037
# A clone landing on an unmapped IP fails fast with a clear error.
#
# This script does NOT enable any role service. The Terraform role-overlays
# render per-host config (Keeper raft id, ClickHouse macros {shard}/{replica},
# StarRocks FE/BE join) and enable exactly one role service per node.
#
# For ClickHouse server nodes it additionally parses {shard}/{replica} from the
# hostname (ch-shardN-repM) and emits NEXUS_CH_SHARD / NEXUS_CH_REPLICA into
# node-identity.env so the server-config overlay renders <macros> from one
# templated CREATE TABLE ... ON CLUSTER without per-node SQL (ADR-0029).
#
# Idempotent: marker at /var/lib/analytics-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/analytics-node-firstboot-done
LOG_PREFIX="[analytics-node-firstboot]"
IDENTITY_DIR=""
IDENTITY_FILE=""

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- analytics tier requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + role + cluster ─────────────────
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: clickhouse +
# cluster: starrocks). Convention: VMnet10 third octet matches the cluster
# (10.40 ClickHouse / 10.30 StarRocks); fourth octet matches VMnet11.
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""
case "$VMNET11_IP" in
  # ─── 0.G.5 -- ClickHouse Keeper quorum (3 nodes) ──────────────────────
  192.168.70.41) HOSTNAME=ch-keeper-1; VMNET10_IP=192.168.10.41; ROLE=clickhouse-keeper; CLUSTER=clickhouse ;;
  192.168.70.42) HOSTNAME=ch-keeper-2; VMNET10_IP=192.168.10.42; ROLE=clickhouse-keeper; CLUSTER=clickhouse ;;
  192.168.70.43) HOSTNAME=ch-keeper-3; VMNET10_IP=192.168.10.43; ROLE=clickhouse-keeper; CLUSTER=clickhouse ;;

  # ─── 0.G.5 -- ClickHouse data nodes (3 shards x 2 replicas) ───────────
  192.168.70.44) HOSTNAME=ch-shard1-rep1; VMNET10_IP=192.168.10.44; ROLE=clickhouse-server; CLUSTER=clickhouse ;;
  192.168.70.45) HOSTNAME=ch-shard1-rep2; VMNET10_IP=192.168.10.45; ROLE=clickhouse-server; CLUSTER=clickhouse ;;
  192.168.70.46) HOSTNAME=ch-shard2-rep1; VMNET10_IP=192.168.10.46; ROLE=clickhouse-server; CLUSTER=clickhouse ;;
  192.168.70.47) HOSTNAME=ch-shard2-rep2; VMNET10_IP=192.168.10.47; ROLE=clickhouse-server; CLUSTER=clickhouse ;;
  192.168.70.48) HOSTNAME=ch-shard3-rep1; VMNET10_IP=192.168.10.48; ROLE=clickhouse-server; CLUSTER=clickhouse ;;
  192.168.70.49) HOSTNAME=ch-shard3-rep2; VMNET10_IP=192.168.10.49; ROLE=clickhouse-server; CLUSTER=clickhouse ;;

  # ─── 0.G.6 -- StarRocks FE quorum (3 nodes) ───────────────────────────
  192.168.70.31) HOSTNAME=sr-fe-leader;     VMNET10_IP=192.168.10.31; ROLE=starrocks-fe; CLUSTER=starrocks ;;
  192.168.70.32) HOSTNAME=sr-fe-follower-1; VMNET10_IP=192.168.10.32; ROLE=starrocks-fe; CLUSTER=starrocks ;;
  192.168.70.33) HOSTNAME=sr-fe-follower-2; VMNET10_IP=192.168.10.33; ROLE=starrocks-fe; CLUSTER=starrocks ;;

  # ─── 0.G.6 -- StarRocks BE nodes (3 nodes) ────────────────────────────
  192.168.70.34) HOSTNAME=sr-be-1; VMNET10_IP=192.168.10.34; ROLE=starrocks-be; CLUSTER=starrocks ;;
  192.168.70.35) HOSTNAME=sr-be-2; VMNET10_IP=192.168.10.35; ROLE=starrocks-be; CLUSTER=starrocks ;;
  192.168.70.36) HOSTNAME=sr-be-3; VMNET10_IP=192.168.10.36; ROLE=starrocks-be; CLUSTER=starrocks ;;

  # ─── 0.L.5 -- StarRocks shared-data FE quorum (3 nodes, ADR-0037) ─────
  192.168.70.37) HOSTNAME=sr-sd-fe-1; VMNET10_IP=192.168.10.37; ROLE=starrocks-sd-fe; CLUSTER=starrocks-sd ;;
  192.168.70.38) HOSTNAME=sr-sd-fe-2; VMNET10_IP=192.168.10.38; ROLE=starrocks-sd-fe; CLUSTER=starrocks-sd ;;
  192.168.70.39) HOSTNAME=sr-sd-fe-3; VMNET10_IP=192.168.10.39; ROLE=starrocks-sd-fe; CLUSTER=starrocks-sd ;;

  # ─── 0.L.5 -- StarRocks shared-data CN nodes (2 nodes, ADR-0037) ──────
  # CN-2 at .40 is the documented decade-spill (SR .3x had only 4 free slots).
  192.168.70.30) HOSTNAME=sr-sd-cn-1; VMNET10_IP=192.168.10.30; ROLE=starrocks-sd-cn; CLUSTER=starrocks-sd ;;
  192.168.70.40) HOSTNAME=sr-sd-cn-2; VMNET10_IP=192.168.10.40; ROLE=starrocks-sd-cn; CLUSTER=starrocks-sd ;;

  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' -- not a 04-analytics tier IP" >&2
    echo "$LOG_PREFIX recognised IPs: ch-keeper-1..3 (.41/.42/.43); ch-shard{1,2,3}-rep{1,2} (.44-.49); sr-fe-{leader,follower-1,follower-2} (.31/.32/.33); sr-be-1..3 (.34/.35/.36); sr-sd-fe-1..3 (.37/.38/.39); sr-sd-cn-1/2 (.30/.40)." >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=$CLUSTER VMnet10=$VMNET10_IP/24"

# Derive per-ROLE identity dir + owning group. Unlike the OLTP tier (keyed on
# cluster), the analytics ClickHouse cluster has two roles (keeper + server)
# with distinct config dirs, so we key on ROLE. The owning group is created by
# the role's Packer task (clickhouse for CH; starrocks for SR).
case "$ROLE" in
  clickhouse-keeper) IDENTITY_DIR=/etc/nexus-clickhouse-keeper; IDENTITY_GROUP=clickhouse ;;
  clickhouse-server) IDENTITY_DIR=/etc/nexus-clickhouse;        IDENTITY_GROUP=clickhouse ;;
  starrocks-fe)      IDENTITY_DIR=/etc/nexus-starrocks;         IDENTITY_GROUP=starrocks  ;;
  starrocks-be)      IDENTITY_DIR=/etc/nexus-starrocks;         IDENTITY_GROUP=starrocks  ;;
  starrocks-sd-fe)   IDENTITY_DIR=/etc/nexus-starrocks;         IDENTITY_GROUP=starrocks  ;;
  starrocks-sd-cn)   IDENTITY_DIR=/etc/nexus-starrocks;         IDENTITY_GROUP=starrocks  ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown ROLE '$ROLE' -- no identity dir mapping" >&2
    exit 1
    ;;
esac
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"

# For ClickHouse server nodes, parse shard + replica index from the hostname
# (ch-shardN-repM) so the server-config overlay can render <macros> per-node.
CH_SHARD=""
CH_REPLICA=""
if [ "$ROLE" = "clickhouse-server" ]; then
  CH_SHARD=$(echo "$HOSTNAME" | sed -n 's/^ch-shard\([0-9]\+\)-rep[0-9]\+$/\1/p')
  CH_REPLICA=$(echo "$HOSTNAME" | sed -n 's/^ch-shard[0-9]\+-rep\([0-9]\+\)$/\1/p')
  if [ -z "$CH_SHARD" ] || [ -z "$CH_REPLICA" ]; then
    echo "$LOG_PREFIX ERROR: could not parse shard/replica from hostname '$HOSTNAME'" >&2
    exit 1
  fi
  echo "$LOG_PREFIX clickhouse macros: shard=$CH_SHARD replica=$CH_REPLICA"
fi

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot the
# udev lex-order match leaves nic1 on its kernel-default name, the static
# .network never applies, the backplane has no IP.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Write the node-identity env file for the Terraform role-overlays ───
mkdir -p "$IDENTITY_DIR"
{
  echo "# Generated by analytics-node-firstboot.sh -- do not edit by hand."
  echo "NEXUS_HOSTNAME=$HOSTNAME"
  echo "NEXUS_ROLE=$ROLE"
  echo "NEXUS_CLUSTER=$CLUSTER"
  echo "NEXUS_VMNET11_IP=$VMNET11_IP"
  echo "NEXUS_VMNET10_IP=$VMNET10_IP"
  if [ "$ROLE" = "clickhouse-server" ]; then
    echo "NEXUS_CH_SHARD=$CH_SHARD"
    echo "NEXUS_CH_REPLICA=$CH_REPLICA"
  fi
} > "$IDENTITY_FILE"
chown "root:$IDENTITY_GROUP" "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE (group=$IDENTITY_GROUP)"

# ─── 8. Mark complete ──────────────────────────────────────────────────────
# No role service is enabled here -- the Terraform role-overlays render the
# per-host config (Keeper raft id, ClickHouse macros, StarRocks FE/BE join)
# then enable exactly one role service per node post-apply.
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role in $CLUSTER cluster on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"

#!/usr/bin/env bash
# Diagnose intermittent Wi-Fi → LB VIP TCP failures (jangroth/homekube#15).
#
# Run from a host on the home Wi-Fi subnet that can reach the cluster LB pool.
# Prerequisites on the test host: kubectl (cluster-admin kubeconfig), arping, curl.
#
# Usage:  ./manual/lb-vip-wifi-debug.sh <VIP> [<interface>]
# Example: ./manual/lb-vip-wifi-debug.sh 192.168.86.241 wlan0

set -euo pipefail

VIP="${1:?Usage: $0 <VIP> [<interface>]}"
IFACE="${2:-}"
BURST_COUNT=100
CURL_TIMEOUT=2   # seconds per request

# ── 1. Identify the Cilium L2 announcement leader ─────────────────────────────
echo "==> Cilium L2 announcement leader"
LEASE=$(kubectl get lease -n kube-system --no-headers \
  | awk '/l2announce/ {print $1; exit}')
if [[ -z "$LEASE" ]]; then
  echo "ERROR: no cilium l2announce lease found in kube-system" >&2
  exit 1
fi
LEADER=$(kubectl get lease -n kube-system "$LEASE" \
  -o jsonpath='{.spec.holderIdentity}')
echo "    lease:  $LEASE"
echo "    leader: $LEADER"

# ── 2. ARP resolution burst ────────────────────────────────────────────────────
echo ""
echo "==> ARP resolution burst (${BURST_COUNT} packets) → VIP ${VIP}"
ARPING_ARGS=("-c" "$BURST_COUNT" "$VIP")
[[ -n "$IFACE" ]] && ARPING_ARGS=("-I" "$IFACE" "${ARPING_ARGS[@]}")
arping "${ARPING_ARGS[@]}" 2>&1 | tail -5

# ── 3. TCP burst test ──────────────────────────────────────────────────────────
echo ""
echo "==> TCP burst (${BURST_COUNT} serial requests) → http://${VIP}"
echo "    Adapt scheme/port/path if the VIP serves on a non-80 port or TLS."
PASS=0; FAIL=0; FAIL_IDS=()
for i in $(seq 1 "$BURST_COUNT"); do
  if curl -sf --max-time "$CURL_TIMEOUT" --connect-timeout "$CURL_TIMEOUT" \
       -o /dev/null "http://${VIP}" 2>/dev/null; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    FAIL_IDS+=("$i")
  fi
done
echo "    result: ${PASS} passed, ${FAIL} failed out of ${BURST_COUNT}"
if [[ "${#FAIL_IDS[@]}" -gt 0 ]]; then
  echo "    failed requests: ${FAIL_IDS[*]}"
fi

# ── 4. Cluster context snapshot ───────────────────────────────────────────────
echo ""
echo "==> Cluster context"
echo ""
echo "    L2 announce leases:"
kubectl get lease -n kube-system --no-headers | grep l2announce || echo "    (none)"
echo ""
echo "    CiliumL2AnnouncementPolicy:"
kubectl get ciliuml2announcementpolicies.cilium.io -A --no-headers 2>/dev/null \
  || echo "    (CRD not available)"
echo ""
echo "    Nodes:"
kubectl get nodes -o wide
echo ""
echo "    Recent cilium-agent restarts / l2announce log lines:"
kubectl -n kube-system logs -l k8s-app=cilium --since=30m 2>/dev/null \
  | grep -iE 'l2announce|restart|error' | tail -20 \
  || echo "    (no matching log lines)"

# ── 5. Next-step guidance ──────────────────────────────────────────────────────
echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "==> TCP failures reproduced (${FAIL}/${BURST_COUNT})."
  echo "    Run concurrent tcpdump on '${LEADER}' while repeating the burst:"
  echo ""
  echo "    kubectl debug node/${LEADER} -it --profile=sysadmin \\"
  echo "      --image=nicolaka/netshoot:latest \\"
  echo "      -- tcpdump -i any -nn 'host ${VIP}' -w /host/tmp/vip-debug.pcap"
  echo ""
  echo "    Then retrieve and inspect:"
  echo "    kubectl cp <debug-pod>:/host/tmp/vip-debug.pcap ./vip-debug.pcap"
  echo "    tcpdump -nn -r ./vip-debug.pcap | head -100"
  echo ""
  echo "    Key things to look for (jangroth/homekube#15):"
  echo "    - TCP SYN reaching the node but no SYN-ACK  → eBPF DNAT drop"
  echo "    - SYN-ACK returned to wrong MAC             → stale ARP on test host"
  echo "    - ARP reply from unexpected MAC             → L2 announce timing gap"
else
  echo "==> No TCP failures in this run — the fault is intermittent."
  echo "    Re-run during peak Wi-Fi congestion or shortly after a node cordon/uncordon."
  echo "    See jangroth/homekube#15 for investigation history."
fi

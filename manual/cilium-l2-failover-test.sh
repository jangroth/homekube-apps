#!/usr/bin/env bash
# Validates Cilium L2 announcement failover (spec 006 §6 acceptance criterion).
# Cordons the current lease holder, confirms the lease moves to another node,
# then uncordons. Safe to run on a live cluster — all changes are reverted.
set -euo pipefail

LEASE_NS="kube-system"
ELIGIBLE_NODES=("pi1" "pi2" "pi3")
WAIT_SECONDS=30

get_leader() {
  kubectl get lease -n "$LEASE_NS" --no-headers \
    | grep -i l2announce \
    | awk '{print $2}' \
    | sed 's|.*/||'
}

echo "=== Cilium L2 Announcement Failover Test ==="

# Step 1: identify current leader
echo
echo "Step 1: identifying current L2-announcement leader…"
kubectl get lease -n "$LEASE_NS" | grep -i l2announce || { echo "ERROR: no L2 announcement lease found"; exit 1; }
LEADER=$(get_leader)
if [[ -z "$LEADER" ]]; then
  echo "ERROR: could not parse lease holder"
  exit 1
fi
echo "  Current leader: $LEADER"

# Step 2: cordon the leader
echo
echo "Step 2: cordoning $LEADER…"
kubectl cordon "$LEADER"

# Ensure we always uncordon on exit
trap 'echo; echo "Cleanup: uncordoning $LEADER…"; kubectl uncordon "$LEADER"; echo "  $LEADER uncordoned."' EXIT

# Step 3: wait for the lease to move
echo
echo "Step 3: waiting up to ${WAIT_SECONDS}s for lease to move to another node…"
NEW_LEADER=""
for i in $(seq 1 "$WAIT_SECONDS"); do
  sleep 1
  NEW_LEADER=$(get_leader)
  if [[ -n "$NEW_LEADER" && "$NEW_LEADER" != "$LEADER" ]]; then
    echo "  Lease moved to: $NEW_LEADER (after ${i}s)"
    break
  fi
  printf "  %ds — still held by %s\r" "$i" "${NEW_LEADER:-<none>}"
done
echo

if [[ -z "$NEW_LEADER" || "$NEW_LEADER" == "$LEADER" ]]; then
  echo "FAIL: lease did not move within ${WAIT_SECONDS}s (holder: ${NEW_LEADER:-<none>})"
  exit 1
fi

EXPECTED=false
for n in "${ELIGIBLE_NODES[@]}"; do
  [[ "$NEW_LEADER" == "$n" ]] && EXPECTED=true && break
done
if [[ "$EXPECTED" == "false" ]]; then
  echo "WARN: new leader '$NEW_LEADER' is not in expected set (${ELIGIBLE_NODES[*]})"
fi

# Step 4: uncordon happens via trap
echo "PASS: lease failed over from $LEADER to $NEW_LEADER"
echo
echo "Step 4: uncordoning $LEADER (via cleanup trap)…"

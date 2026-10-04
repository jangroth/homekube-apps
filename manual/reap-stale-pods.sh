#!/usr/bin/env bash
# Identifies and deletes stale Error/Unknown pods left behind after node outages.
# Pods in these states that are older than a configurable threshold are considered
# ghost pods that survived past the controller-manager's GC window.
#
# Usage: ./reap-stale-pods.sh [--dry-run] [--min-age-days N]
#
# Options:
#   --dry-run         Print what would be deleted without deleting (default: off)
#   --min-age-days N  Only delete pods older than N days (default: 1)

set -euo pipefail

DRY_RUN=false
MIN_AGE_DAYS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --min-age-days)  MIN_AGE_DAYS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== Stale pod reaper ==="
echo "Mode:        $([ "$DRY_RUN" = true ] && echo DRY-RUN || echo LIVE)"
echo "Min age:     ${MIN_AGE_DAYS} day(s)"
echo ""

# Collect pods in Error or Unknown phase
stale=$(kubectl get pods -A \
  --field-selector 'status.phase!=Running,status.phase!=Pending,status.phase!=Succeeded' \
  -o json 2>/dev/null \
  | jq -r --argjson min_days "$MIN_AGE_DAYS" '
      .items[]
      | select(.status.phase == "Failed" or .status.phase == "Unknown"
               or (.status.conditions // [] | map(.type == "Ready" and .status == "False") | any))
      | select(
          (now - (.metadata.creationTimestamp | fromdateiso8601)) / 86400 >= $min_days
        )
      | "\(.metadata.namespace) \(.metadata.name) \(.status.phase) \(.metadata.creationTimestamp)"
    ' 2>/dev/null || true)

# Also catch any pod whose containerStatuses are all Terminated/Error
terminated=$(kubectl get pods -A \
  -o json 2>/dev/null \
  | jq -r --argjson min_days "$MIN_AGE_DAYS" '
      .items[]
      | select(
          (.status.containerStatuses // [] | length > 0)
          and (.status.containerStatuses | all(.state.terminated != null or .state.waiting.reason == "Error"))
          and ((.status.containerStatuses[0].state.terminated.finishedAt // .metadata.creationTimestamp)
               | (now - fromdateiso8601) / 86400 >= $min_days)
        )
      | "\(.metadata.namespace) \(.metadata.name) \(.status.phase // "Unknown") \(.metadata.creationTimestamp)"
    ' 2>/dev/null || true)

# Merge and deduplicate
all_stale=$(printf '%s\n%s\n' "$stale" "$terminated" \
  | sort -u \
  | grep -v '^[[:space:]]*$' || true)

if [[ -z "$all_stale" ]]; then
  echo "No stale pods found (Error/Unknown, older than ${MIN_AGE_DAYS} day(s))."
  echo ""
  echo "If you expected stale pods, run: kubectl get pods -A | grep -vE 'Running|Completed|Pending'"
  exit 0
fi

echo "Stale pods to delete:"
echo "---------------------"
count=0
while IFS= read -r line; do
  ns=$(awk '{print $1}' <<< "$line")
  name=$(awk '{print $2}' <<< "$line")
  phase=$(awk '{print $3}' <<< "$line")
  created=$(awk '{print $4}' <<< "$line")
  printf "  %-30s %-50s %-12s %s\n" "$ns" "$name" "$phase" "$created"
  count=$((count + 1))
done <<< "$all_stale"
echo "---------------------"
echo "Total: ${count} pod(s)"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN: no pods deleted. Re-run without --dry-run to delete."
  exit 0
fi

read -r -p "Delete all ${count} pod(s)? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Deleting pods..."
deleted=0
failed=0
while IFS= read -r line; do
  ns=$(awk '{print $1}' <<< "$line")
  name=$(awk '{print $2}' <<< "$line")
  if kubectl delete pod -n "$ns" "$name" --grace-period=0 --force 2>/dev/null; then
    echo "  deleted  ${ns}/${name}"
    deleted=$((deleted + 1))
  else
    echo "  FAILED   ${ns}/${name}"
    failed=$((failed + 1))
  fi
done <<< "$all_stale"

echo ""
echo "Done: ${deleted} deleted, ${failed} failed."

if [[ $deleted -gt 0 ]]; then
  echo ""
  echo "=== Post-deletion check ==="
  echo "Remaining non-Running/Completed pods:"
  kubectl get pods -A | grep -vE 'Running|Completed|Pending|NAME' || echo "  (none)"
fi

echo ""
echo "=== Preventing recurrence ==="
echo "Default terminated-pod-gc-threshold is 12500. To lower it so the"
echo "controller-manager self-cleans after node outages, set:"
echo ""
echo "  KubeControllerManagerConfiguration.controllerManager.terminatedPodGCThreshold: 100"
echo ""
echo "in roles/k8s-control-plane/files/kubeadm-config.yaml (homekube repo)"
echo "and re-run the control-plane role."

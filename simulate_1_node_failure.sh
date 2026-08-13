#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"
TIMEOUT_SECONDS=900 # Maximum time to wait for node/pod recovery (15 minutes)
POLL_INTERVAL=5     # Seconds between checks

# --- Functions ---
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@" >&2
}

wait_for_node_ready() {
  local node_name=$1
  log "Waiting for node $node_name to be (re)created and Ready..."
  local end_time=$((SECONDS + TIMEOUT_SECONDS))
  while [ $SECONDS -lt $end_time ]; do
    local node_status=$(kubectl get node "$node_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
    if [ "$node_status" == "True" ]; then
      log "Node $node_name is Ready."
      return 0
    elif [ "$node_status" == "NotFound" ]; then
      log "Node $node_name not found yet, waiting..."
    else
      log "Node $node_name not Ready. Current Ready status: '$node_status'."
    fi
    sleep $POLL_INTERVAL
  done
  log "ERROR: Node $node_name did not become Ready within $TIMEOUT_SECONDS seconds."
  return 1
}

wait_for_pod_running() {
  local node_name=$1
  log "Waiting for a pod matching label $LABEL_SELECTOR on node $node_name to be Running & Ready..."
  local end_time=$((SECONDS + TIMEOUT_SECONDS))
  local pod_name=""
  while [ $SECONDS -lt $end_time ]; do
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector spec.nodeName="$node_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$pod_name" ]; then
      local pod_phase=$(kubectl get pod -n "$NAMESPACE" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
      local pod_ready=$(kubectl get pod -n "$NAMESPACE" "$pod_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

      if [ "$pod_phase" == "Running" ] && [ "$pod_ready" == "True" ]; then
        log "Pod $pod_name is Running and Ready on node $node_name."
        return 0
      fi
      log "Pod $pod_name found on $node_name, but not fully Ready. Phase: $pod_phase, Ready: $pod_ready"
    else
      log "No pod with label $LABEL_SELECTOR yet scheduled on node $node_name."
    fi
    sleep $POLL_INTERVAL
  done
  log "ERROR: No pod matching label $LABEL_SELECTOR became Running and Ready on node $node_name within $TIMEOUT_SECONDS seconds."
  return 1
}

# --- Main Execution ---
log "Starting optimized single-node failure simulation..."

# 1. Get a random node from the current cluster
NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
NUM_NODES=${#NODES[@]}
if [ "$NUM_NODES" -eq 0 ]; then
  log "ERROR: No nodes found in the cluster."
  exit 1
fi
RANDOM_INDEX=$((RANDOM % NUM_NODES))
NODE_TO_DELETE=${NODES[$RANDOM_INDEX]}

NODE_ZONE=$(kubectl get node "$NODE_TO_DELETE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
if [ -z "$NODE_ZONE" ]; then
    log "ERROR: Could not determine zone for node $NODE_TO_DELETE."
    exit 1
fi
log "Selected random node to delete: $NODE_TO_DELETE in zone $NODE_ZONE"

# 2. Delete the node (and immediately force-delete K8s node object to release VolumeAttachment lock)
log "Deleting GCE instance $NODE_TO_DELETE in zone $NODE_ZONE..."
gcloud compute instances delete "$NODE_TO_DELETE" --zone "$NODE_ZONE" --quiet &
gcloud_pid=$!

kubectl delete node "$NODE_TO_DELETE" --grace-period=0 --force --wait=false >/dev/null 2>&1 &

wait "$gcloud_pid" || true
log "Instance deletion command completed for $NODE_TO_DELETE."

# 3. Wait for the node to be back and ready
if ! wait_for_node_ready "$NODE_TO_DELETE"; then
  exit 1
fi

# 4. Wait for the new pod to be running on the node
if ! wait_for_pod_running "$NODE_TO_DELETE"; then
  exit 1
fi

log "Node and pod are ready on $NODE_TO_DELETE. Proceeding to resume FIO load..."
sleep 5

# 5. Call install_fio.sh (installs in parallel, skips existing)
log "Running ./install_fio.sh..."
if ! ./install_fio.sh; then
  log "ERROR: install_fio.sh failed."
  exit 1
fi
log "install_fio.sh completed."

# 6. Call run_fio.sh (starts in parallel)
log "Running ./run_fio.sh..."
if ! ./run_fio.sh; then
  log "ERROR: run_fio.sh failed."
  exit 1
fi
log "run_fio.sh completed."

log "Single-node failure simulation and workload recovery complete for node $NODE_TO_DELETE."

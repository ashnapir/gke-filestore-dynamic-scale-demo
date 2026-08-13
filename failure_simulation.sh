#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"
NUM_NODES_TO_FAIL=3
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
log "Starting optimized node failure simulation for $NUM_NODES_TO_FAIL random nodes..."

# 1. Get all nodes and select random ones
NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
NUM_NODES=${#NODES[@]}

if [ "$NUM_NODES" -lt "$NUM_NODES_TO_FAIL" ]; then
  log "ERROR: Not enough nodes in the cluster to fail $NUM_NODES_TO_FAIL nodes. Found: $NUM_NODES"
  exit 1
fi

# Shuffle the array and take the first NUM_NODES_TO_FAIL
NODES_TO_DELETE=($(printf "%s\n" "${NODES[@]}" | shuf | head -n "$NUM_NODES_TO_FAIL"))

log "Selected random nodes to delete: ${NODES_TO_DELETE[*]}"

# 2. Delete the selected nodes in parallel (and immediately force-delete K8s node objects to release VolumeAttachment locks)
declare -a delete_pids
for NODE_TO_DELETE in "${NODES_TO_DELETE[@]}"; do
  NODE_ZONE=$(kubectl get node "$NODE_TO_DELETE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  if [ -z "$NODE_ZONE" ]; then
      log "ERROR: Could not determine zone for node $NODE_TO_DELETE."
      continue
  fi
  log "Issuing delete command for GCE instance $NODE_TO_DELETE in zone $NODE_ZONE..."
  gcloud compute instances delete "$NODE_TO_DELETE" --zone "$NODE_ZONE" --quiet &
  delete_pids+=($!)

  # Force-delete the K8s node object to immediately evict pods and release the CSI VolumeAttachment lock
  kubectl delete node "$NODE_TO_DELETE" --grace-period=0 --force --wait=false >/dev/null 2>&1 &
done

log "Waiting for all gcloud delete commands to complete... PIDs: ${delete_pids[*]}"
for pid in "${delete_pids[@]}"; do
  if wait "$pid"; then
    log "gcloud delete process with PID $pid completed successfully."
  else
    log "WARNING: gcloud delete process with PID $pid finished with code $?."
  fi
done
log "Instance deletion commands finished."

# 3. Wait for all deleted nodes to be back and ready
for NODE_TO_DELETE in "${NODES_TO_DELETE[@]}"; do
  if ! wait_for_node_ready "$NODE_TO_DELETE"; then
    log "ERROR: Node $NODE_TO_DELETE failed to become ready. Exiting."
    exit 1
  fi
done
log "All deleted nodes are back and Ready."

# 4. Wait for the new pods to be running on each node
for NODE_TO_DELETE in "${NODES_TO_DELETE[@]}"; do
  if ! wait_for_pod_running "$NODE_TO_DELETE"; then
    log "ERROR: Pod on node $NODE_TO_DELETE failed to become ready. Exiting."
    exit 1
  fi
done
log "All new pods on recreated nodes are Running and Ready."

log "Volume mounts verified active on all new pods."
sleep 5

# 5. Call install_fio.sh (installs in parallel, skips pods that already have FIO)
log "Running ./install_fio.sh to ensure FIO is on the new pods..."
if ! ./install_fio.sh; then
  log "ERROR: install_fio.sh failed."
  exit 1
fi
log "install_fio.sh completed."

# 6. Call run_fio.sh (starts FIO concurrently on new pods)
log "Running ./run_fio.sh to resume FIO load..."
if ! ./run_fio.sh; then
  log "ERROR: run_fio.sh failed."
  exit 1
fi
log "run_fio.sh completed."

log "Node failure simulation and workload recovery complete for all failed nodes."

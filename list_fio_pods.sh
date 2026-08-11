#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"
PVC_NAME="fio-dynamic-pvc" # The PVC name used by the pods

# --- Functions ---
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@" >&2 # Redirect log messages to stderr
}

# Function to retry kubectl commands expected to return a value on stdout
kubectl_retry() {
  local retries=3
  local delay=3
  local cmd_output
  local args=("$@")
  local attempt=1
  while [ $attempt -le $retries ]; do
    if cmd_output=$("${args[@]}" 2>/dev/null); then
      if [ -n "$cmd_output" ]; then
        echo "$cmd_output"
        return 0
      else
        log "WARN: kubectl command succeeded but returned empty: ${args[*]}"
      fi
    else
      log "WARN: kubectl command failed with exit code $?."
    fi
    if [ $attempt -lt $retries ]; then
      log "Waiting $delay seconds to retry..."
      sleep $delay
    fi
    attempt=$((attempt + 1))
  done
  log "ERROR: kubectl command failed or returned empty after $retries retries: ${args[*]}"
  return 1
}

# --- Get Expected Mount Source from PV ---
PV_NAME=$(kubectl_retry kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
if [ -z "$PV_NAME" ]; then
  log "ERROR: Could not get PV name from PVC $PVC_NAME. Check if PVC exists and is Bound."
  exit 1
fi

EXPECTED_FILESTORE_IP=$(kubectl_retry kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeAttributes.ip}')
EXPECTED_FILESTORE_SHARE=$(kubectl_retry kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeAttributes.volume}')

if [ -z "$EXPECTED_FILESTORE_IP" ] || [ -z "$EXPECTED_FILESTORE_SHARE" ]; then
  log "ERROR: Could not retrieve IP or Share from PV $PV_NAME."
  exit 1
fi
EXPECTED_MOUNT="${EXPECTED_FILESTORE_IP}:/${EXPECTED_FILESTORE_SHARE}"
log "Expecting mounts to be: $EXPECTED_MOUNT"
echo "" >&2

# --- Check Pods ---
PODS_NODES=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}')

if [ -z "$PODS_NODES" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

echo "Checking Pod Status (FIO Process & Mount):"
printf "%-45s | %-55s | %-40s | %-7s | %-10s\n" "Pod" "Node" "Mount Source" "Mounted" "FIO Status"
echo "---------------------------------------------+---------------------------------------------------------+------------------------------------------+---------+------------"

while IFS=$'\t' read -r pod_name node_name; do
  # Check Mount
  mount_source=$(kubectl exec "$pod_name" -n "$NAMESPACE" -- /bin/sh -c "df /mnt/filestore 2>/dev/null | awk 'NR==2 {print \$1}'" 2>/dev/null)

  mounted_status="No"
  display_mount_source="${mount_source:-(Not Mounted)}"

  if [ -n "$mount_source" ]; then
    if [ "$mount_source" == "$EXPECTED_MOUNT" ]; then
      mounted_status="Yes"
    else
      display_mount_source="${mount_source} (WRONG!)"
    fi
  fi

  # Check FIO Process
  TARGET_DIR="/mnt/filestore/fio-test-$pod_name"
  FIO_NAME="random-read" # Match the name in run_fio.sh
  fio_status="MISSING"
  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "pgrep -f 'fio --name=${FIO_NAME}.*--directory=${TARGET_DIR}' > /dev/null" 2>/dev/null; then
    fio_status="RUNNING"
  fi

  printf "%-45s | %-55s | %-40s | %-7s | %-10s\n" "$pod_name" "$node_name" "$display_mount_source" "$mounted_status" "$fio_status"
done <<< "$PODS_NODES"

echo "---------------------------------------------+---------------------------------------------------------+------------------------------------------+---------+------------"
echo "Check complete."


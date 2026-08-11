#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

FIO_NAME="random-read" # Must match the --name used in run_fio.sh

echo "Stopping FIO '$FIO_NAME' processes on pods: $PODS"
echo "-------------------------------------"

for pod_name in $PODS; do
  echo "--- Processing pod: $pod_name ---"
  TARGET_DIR="/mnt/filestore/fio-test-$pod_name"

  # This pattern is quite specific to the command launched by run_fio.sh
  # It looks for a process with "fio" and the essential unique arguments.
  PGREP_PATTERN="fio --name=${FIO_NAME}.*--directory=${TARGET_DIR}"

  # Get PIDs of matching processes
  PIDS=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "pgrep -f \"${PGREP_PATTERN}\"" 2>/dev/null || true)

  if [ -n "$PIDS" ]; then
    for PID in $PIDS; do
      # Double check it's not the pgrep command itself, though unlikely with this pattern
      if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "grep -q '${PGREP_PATTERN}' /proc/${PID}/cmdline" 2>/dev/null; then
        echo "  Found FIO PID: $PID on $pod_name. Sending TERM signal..."
        if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "kill ${PID}" 2>/dev/null; then
           echo "    Kill signal sent to PID $PID."
        else
           echo "    Failed to send kill to PID $PID on $pod_name (it might have already exited)."
        fi
      fi
    done
  else
    echo "  No matching FIO process found on $pod_name."
  fi
  sleep 0.1
done

echo "-------------------------------------"
echo "Stop commands issued. Verify with list_fio_pods.sh in a few seconds."


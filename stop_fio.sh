#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

echo "Stopping FIO processes on pods: $PODS"
echo "-------------------------------------"

for pod_name in $PODS; do
  TARGET_DIR="/mnt/filestore/fio-test-$pod_name"
  FIO_NAME="random-read-write"

  # The pattern should match the command line of the running FIO process
  KILL_PATTERN="fio --name=${FIO_NAME}.*--directory=${TARGET_DIR}"

  echo "Attempting to stop FIO on pod: $pod_name"

  # Execute pkill -f inside the pod.
  # pkill returns 0 if process(es) were matched and signaled, 1 if no process matched.
  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "pkill -f \"${KILL_PATTERN}\""; then
    echo "  Kill signal sent to matching FIO process(es) on $pod_name."
  else
    # This means pkill exited non-zero, likely because no process matched.
    echo "  No matching FIO process found to kill on $pod_name."
  fi
  # Give a moment for the process to terminate if it was found
  sleep 1
done

echo "-------------------------------------"
echo "Stop commands issued. Verify with list_fio_pods.sh"


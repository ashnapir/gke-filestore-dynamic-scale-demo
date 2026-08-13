#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

echo "Checking and installing FIO in parallel across pods..."

install_on_pod() {
  local pod_name=$1
  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "command -v fio >/dev/null 2>&1" 2>/dev/null; then
    echo "=== FIO already installed on $pod_name (skipped)"
  else
    echo ">>> Installing FIO on pod: $pod_name"
    if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "apk update && apk add fio --no-cache" >/dev/null 2>&1; then
      echo "=== FIO installation successful on $pod_name"
    else
      echo "XXX FIO installation failed on $pod_name"
      return 1
    fi
  fi
}

pids=()
for pod_name in $PODS; do
  install_on_pod "$pod_name" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo "FIO installation process complete."

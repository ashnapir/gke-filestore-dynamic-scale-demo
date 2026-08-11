#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

for pod_name in $PODS; do
  echo ">>> Installing FIO on pod: $pod_name"
  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "apk update && apk add fio --no-cache"; then
    echo "=== FIO installation successful on $pod_name"
  else
    echo "XXX FIO installation failed on $pod_name"
  fi
done
echo "FIO installation process complete."


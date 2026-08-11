#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

echo "Checking and starting FIO tests on pods: $PODS"

for pod_name in $PODS; do
  TARGET_DIR="/mnt/filestore/fio-test-$pod_name"
  FIO_NAME="random-reads-load"
  LOG_FILE="/tmp/fio_${FIO_NAME}.log"

  echo "--- Processing pod: $pod_name ---"

  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "pgrep -f 'fio --name=${FIO_NAME}.*--directory=${TARGET_DIR}' > /dev/null" 2>/dev/null; then
    echo "    FIO process seems to be already running on $pod_name. Skipping."
  else
    echo "    FIO process not found on $pod_name. Starting FIO..."

    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "mkdir -p $TARGET_DIR"; then
      echo "    XXX Failed to create directory $TARGET_DIR in $pod_name. Skipping FIO start."
      continue
    fi
    echo "    Directory $TARGET_DIR ensured."

    if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "nohup fio --name=${FIO_NAME} \
        --ioengine=libaio \
        --iodepth=3 \
        --rw=randread \
        --bs=4k \
        --direct=1 \
        --size=256M \
        --numjobs=1 \
        --runtime=3600 \
        --time_based \
        --group_reporting \
        --directory=${TARGET_DIR} > ${LOG_FILE} 2>&1 &"; then
      echo "    FIO command initiated in the background on $pod_name. Log: ${LOG_FILE}"
    else
      echo "    XXX Failed to start FIO on $pod_name."
    fi
  fi
done

echo "FIO check and start process complete."


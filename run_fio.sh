#!/bin/bash
NAMESPACE="default"
LABEL_SELECTOR="app=fio-tester"

PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
  echo "No pods found with label $LABEL_SELECTOR in namespace $NAMESPACE"
  exit 1
fi

echo "Checking and starting FIO tests in parallel on pods: $PODS"

run_on_pod() {
  local pod_name=$1
  local target_dir="/mnt/filestore/fio-test-$pod_name"
  local fio_name="random-reads-load"
  local log_file="/tmp/fio_${fio_name}.log"

  if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "pgrep -f 'fio --name=${fio_name}.*--directory=${target_dir}' > /dev/null" 2>/dev/null; then
    echo "    [Pod $pod_name] FIO process already running. Skipping."
  else
    echo "    [Pod $pod_name] Starting FIO..."
    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "mkdir -p $target_dir" 2>/dev/null; then
      echo "    [Pod $pod_name] XXX Failed to create directory $target_dir. Skipping FIO start."
      return 1
    fi

    if kubectl exec -n "$NAMESPACE" "$pod_name" -- /bin/sh -c "nohup fio --name=${fio_name} \
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
        --directory=${target_dir} > ${log_file} 2>&1 &" >/dev/null 2>&1; then
      echo "    [Pod $pod_name] FIO command initiated in background. Log: ${log_file}"
    else
      echo "    [Pod $pod_name] XXX Failed to start FIO."
      return 1
    fi
  fi
}

pids=()
for pod_name in $PODS; do
  run_on_pod "$pod_name" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo "FIO check and start process complete."

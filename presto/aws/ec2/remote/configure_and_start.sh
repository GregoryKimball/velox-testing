#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ ${WORKER_ENGINE:-} == trino ]]; then
  exec bash "$(dirname "$0")/configure_and_start_trino.sh"
fi

required=(
  RUN_ID ROLE WORKER_COUNT COORDINATOR_ADDRESS AWS_REGION VCPU_PER_WORKER
  TASK_MAX_DRIVERS_PER_TASK HIVE_MAX_SPLIT_SIZE
  HIVE_SPLIT_LOADER_CONCURRENCY DYNAMIC_FILTERING_ENABLED
  CPU_EXCHANGE_TUNING_ENABLED
  COORDINATOR_HEAP_GIB COORDINATOR_HEADROOM_GIB
  COORDINATOR_QUERY_TOTAL_MEMORY_PER_NODE_GIB
  COORDINATOR_QUERY_MEMORY_PER_NODE_GIB WORKER_SYSTEM_MEMORY_GIB
  WORKER_QUERY_MEMORY_GIB WORKER_MEMORY_LIMIT_GIB WORKER_MEMORY_SHRINK_GIB
  ASYNC_DATA_CACHE_ENABLED ASYNC_CACHE_SSD_GIB ASYNC_CACHE_NUM_SHARDS
  COORDINATOR_IMAGE WORKER_IMAGE WORKER_ENGINE
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "missing required environment variable: ${name}" >&2
    exit 2
  fi
done

if [[ ${ROLE} != coordinator && ${ROLE} != worker ]]; then
  echo "ROLE must be coordinator or worker" >&2
  exit 2
fi
if [[ ${WORKER_ENGINE} != native && ${WORKER_ENGINE} != java && ${WORKER_ENGINE} != gpu ]]; then
  echo "WORKER_ENGINE must be native, java or gpu" >&2
  exit 2
fi
# gpu is a native (Presto C++) worker with cuDF; it shares the native config files.
native=false
if [[ ${WORKER_ENGINE} == native || ${WORKER_ENGINE} == gpu ]]; then
  native=true
fi
if [[ ${ROLE} == worker && -z ${WORKER_INDEX:-} ]]; then
  echo "WORKER_INDEX is required for worker role" >&2
  exit 2
fi

repo=/opt/velox-testing
runtime_root=/opt/presto-aws
variant=cpu
config_kind=native
if [[ ${WORKER_ENGINE} == java ]]; then
  variant=java
  config_kind=java
elif [[ ${WORKER_ENGINE} == gpu ]]; then
  variant=gpu
fi
generated="${repo}/presto/docker/config/generated/${variant}"
base="${runtime_root}/base_config/${ROLE}"
final="${runtime_root}/final_config/${ROLE}"
assembled="${runtime_root}/runtime_etc"

set_property() {
  local path=$1 key=$2 value=$3
  python3 - "${path}" "${key}" "${value}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
prefix = f"{key}="
lines = path.read_text().splitlines()
matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one {key} in {path}; found {len(matches)}")
lines[matches[0]] = f"{key}={value}"
path.write_text("\n".join(lines) + "\n")
PY
}

upsert_property() {
  local path=$1 key=$2 value=$3
  python3 - "${path}" "${key}" "${value}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
prefix = f"{key}="
lines = path.read_text().splitlines()
matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
if len(matches) > 1:
    raise SystemExit(f"expected at most one {key} in {path}; found {len(matches)}")
if matches:
    lines[matches[0]] = f"{key}={value}"
else:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
PY
}

delete_property() {
  local path=$1 key=$2
  python3 - "${path}" "${key}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
prefix = f"{sys.argv[2]}="
lines = [line for line in path.read_text().splitlines() if not line.startswith(prefix)]
path.write_text("\n".join(lines) + "\n")
PY
}

cd "${repo}/presto/scripts"
OVERWRITE_CONFIG=true \
NUM_WORKERS="${WORKER_COUNT}" \
VARIANT_TYPE="${variant}" \
VCPU_PER_WORKER="${VCPU_PER_WORKER}" \
  ./generate_presto_config.sh

rm -rf "${base}" "${final}" "${assembled}"
mkdir -p "${base}" "${final}" "${assembled}" "${runtime_root}/data"

if [[ ${ROLE} == coordinator ]]; then
  cp -a "${generated}/etc_common/." "${base}/"
  cp "${generated}/etc_coordinator/config_${config_kind}.properties" "${base}/config.properties"
  cp "${generated}/etc_coordinator/node.properties" "${base}/node.properties"
  mkdir -p "${base}/catalog"
  cp "${generated}/etc_coordinator/catalog/hive.properties" "${base}/catalog/hive.properties"
else
  worker_source="${generated}/etc_worker_0"
  cp -a "${generated}/etc_common/." "${base}/"
  cp "${worker_source}/config_${config_kind}.properties" "${base}/config.properties"
  cp "${worker_source}/node.properties" "${base}/node.properties"
  mkdir -p "${base}/catalog"
  cp "${worker_source}/catalog/hive.properties" "${base}/catalog/hive.properties"
fi
cp -a "${base}/." "${final}/"
if [[ ${WORKER_ENGINE} == gpu && ${ROLE} == worker ]]; then
  rm -f "${final}/catalog/iceberg.properties"
elif [[ ${WORKER_ENGINE} == native && ${ROLE} == worker ]]; then
  sed 's/^connector\.name=.*/connector.name=iceberg/' \
    "${final}/catalog/hive.properties" >"${final}/catalog/iceberg.properties"
elif [[ ! -f ${final}/catalog/iceberg.properties ]]; then
  cat >"${final}/catalog/iceberg.properties" <<'EOF'
connector.name=iceberg
hive.metastore=file
hive.metastore.catalog.dir=file:/var/lib/presto/data/hive/metastore
hive.s3.ssl.enabled=true
hive.s3.path-style-access=false
hive.s3.use-instance-credentials=true
EOF
fi
delete_property "${final}/catalog/hive.properties" hive.max-split-size
printf 'hive.max-split-size=%s\n' "${HIVE_MAX_SPLIT_SIZE}" \
  >>"${final}/catalog/hive.properties"
delete_property "${final}/catalog/hive.properties" hive.split-loader-concurrency
printf 'hive.split-loader-concurrency=%s\n' "${HIVE_SPLIT_LOADER_CONCURRENCY}" \
  >>"${final}/catalog/hive.properties"
if [[ ${WORKER_ENGINE} == java ]]; then
  upsert_property "${final}/catalog/hive.properties" \
    hive.s3.use-instance-credentials true
fi
if [[ ${WORKER_ENGINE} == java || ${ROLE} == coordinator ]]; then
  upsert_property "${final}/catalog/iceberg.properties" \
    hive.s3.use-instance-credentials true
  upsert_property "${final}/catalog/iceberg.properties" \
    writer-sort-buffer-size "${ICEBERG_WRITER_SORT_BUFFER_SIZE:-64MB}"
  upsert_property "${final}/catalog/iceberg.properties" \
    max-open-sort-files "${ICEBERG_MAX_OPEN_SORT_FILES:-50}"
fi

if [[ ${ROLE} == coordinator ]]; then
  set_property "${final}/config.properties" discovery.uri \
    "http://${COORDINATOR_ADDRESS}:8080"
  set_property "${final}/config.properties" query-manager.required-workers \
    "${WORKER_COUNT}"
  set_property "${final}/config.properties" \
    query-manager.required-workers-max-wait 10m
  set_property "${final}/config.properties" query.max-total-memory-per-node \
    "${COORDINATOR_QUERY_TOTAL_MEMORY_PER_NODE_GIB}GB"
  set_property "${final}/config.properties" query.max-total-memory \
    "$((COORDINATOR_QUERY_TOTAL_MEMORY_PER_NODE_GIB * WORKER_COUNT))GB"
  set_property "${final}/config.properties" query.max-memory-per-node \
    "${COORDINATOR_QUERY_MEMORY_PER_NODE_GIB}GB"
  set_property "${final}/config.properties" query.max-memory \
    "$((COORDINATOR_QUERY_MEMORY_PER_NODE_GIB * WORKER_COUNT))GB"
  set_property "${final}/config.properties" memory.heap-headroom-per-node \
    "${COORDINATOR_HEADROOM_GIB}GB"
  if [[ ${native} == true ]]; then
    set_property "${final}/config.properties" single-node-execution-enabled false
    set_property "${final}/config.properties" experimental.enable-dynamic-filtering \
      "${DYNAMIC_FILTERING_ENABLED}"
  fi
  if [[ ${WORKER_ENGINE} == gpu ]]; then
    cat >"${final}/session-property-config.properties" <<'EOF'
session-property-config.configuration-manager=file
session-property-manager.config-file=/opt/presto-server/etc/session-property-config.json
EOF
    printf '%s\n' '[{"sessionProperties":{"native_cudf_exchange_enabled":"true"}}]' \
      >"${final}/session-property-config.json"
  fi
  python3 - "${final}/jvm.config" "${COORDINATOR_HEAP_GIB}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
heap = sys.argv[2]
lines = path.read_text().splitlines()
lines = [
    f"-Xmx{heap}G" if line.startswith("-Xmx") else
    f"-Xms{heap}G" if line.startswith("-Xms") else line
    for line in lines
]
path.write_text("\n".join(lines) + "\n")
PY
else
  set_property "${final}/config.properties" http-server.http.port 8080
  set_property "${final}/config.properties" discovery.uri \
    "http://${COORDINATOR_ADDRESS}:8080"
  if [[ ${native} == true ]]; then
    set_property "${final}/config.properties" single-node-execution-enabled false
    set_property "${final}/config.properties" task.max-drivers-per-task \
      "${TASK_MAX_DRIVERS_PER_TASK}"
    set_property "${final}/config.properties" system-memory-gb \
      "${WORKER_SYSTEM_MEMORY_GIB}"
    set_property "${final}/config.properties" query-memory-gb \
      "${WORKER_QUERY_MEMORY_GIB}"
    set_property "${final}/config.properties" query.max-memory-per-node \
      "${WORKER_QUERY_MEMORY_GIB}GB"
    set_property "${final}/config.properties" system-mem-limit-gb \
      "${WORKER_MEMORY_LIMIT_GIB}"
    set_property "${final}/config.properties" system-mem-shrink-gb \
      "${WORKER_MEMORY_SHRINK_GIB}"
    set_property "${final}/config.properties" async-data-cache-enabled \
      "${ASYNC_DATA_CACHE_ENABLED}"
    upsert_property "${final}/config.properties" async-cache-ssd-gb \
      "${ASYNC_CACHE_SSD_GIB}"
    upsert_property "${final}/config.properties" async-cache-num-shards \
      "${ASYNC_CACHE_NUM_SHARDS}"
    upsert_property "${final}/config.properties" runtime-metrics-collection-enabled \
      true
    if [[ ${CPU_EXCHANGE_TUNING_ENABLED} == false ]]; then
      for key in \
        exchange.http-client.enable-connection-pool \
        exchange.max-buffer-size \
        sink.max-buffer-size \
        exchange.max-response-size \
        exchange.client-threads \
        exchange.http-client.max-connections \
        exchange.http-client.max-connections-per-server \
        exchange.http-client.max-requests-queued-per-destination \
        exchange.http-client.request-timeout; do
        delete_property "${final}/config.properties" "${key}"
      done
    fi
    if ((ASYNC_CACHE_SSD_GIB > 0)); then
      if [[ -z ${ASYNC_CACHE_SSD_PATH:-} ]]; then
        echo "ASYNC_CACHE_SSD_PATH is required for SSD cache" >&2
        exit 2
      fi
      upsert_property "${final}/config.properties" async-cache-ssd-path \
        "${ASYNC_CACHE_SSD_PATH}"
    fi
    if [[ ${WORKER_ENGINE} == gpu ]]; then
      # The UCX exchange listens on the HTTP port + 3; peers derive it from the task URI.
      gpu_batch_rows=${GPU_BATCH_ROWS:-30000000}
      for property in \
        cudf.enabled=true \
        cudf.exchange=true \
        cudf.exchange.server.port=8083 \
        "cudf.memory_resource=${GPU_CUDF_MEMORY_RESOURCE:-async}" \
        cudf.jit_expression_enabled=false \
        cudf.concat_optimization_enabled=true \
        "cudf.partitioned_output_batch_rows=${gpu_batch_rows}" \
        "cudf.batch_size_min_threshold=${gpu_batch_rows}" \
        "driver.max-split-preload=${GPU_SPLIT_PRELOAD:-2}" \
        ucxx.blocking_polling=false \
        ucxx.error_handling=false; do
        upsert_property "${final}/config.properties" "${property%%=*}" "${property#*=}"
      done
      if [[ ${GPU_EXCHANGE_COMPRESSION:-none} != none ]]; then
        for property in \
          "cudf.exchange_compression=${GPU_EXCHANGE_COMPRESSION}" \
          cudf.exchange_compression_min_bytes=16777216 \
          cudf.exchange_compression_pipeline=true \
          cudf.exchange_compression_pipeline_threads=1 \
          cudf.exchange_compression_safety_margin=1.50; do
          upsert_property "${final}/config.properties" "${property%%=*}" "${property#*=}"
        done
      fi
      upsert_property "${final}/catalog/hive.properties" cudf.hive.use-buffered-input \
        "${GPU_USE_BUFFERED_INPUT:-false}"
      upsert_property "${final}/catalog/hive.properties" parquet.reader.chunk-read-limit \
        "${GPU_PARQUET_CHUNK_READ_LIMIT:-0}"
      upsert_property "${final}/catalog/hive.properties" parquet.reader.pass-read-limit \
        "${GPU_PARQUET_PASS_READ_LIMIT:-0}"
    fi
  else
    upsert_property "${final}/config.properties" query.max-total-memory-per-node \
      "${COORDINATOR_QUERY_TOTAL_MEMORY_PER_NODE_GIB}GB"
    upsert_property "${final}/config.properties" query.max-memory-per-node \
      "${WORKER_QUERY_MEMORY_GIB}GB"
    upsert_property "${final}/config.properties" memory.heap-headroom-per-node \
      "${COORDINATOR_HEADROOM_GIB}GB"
    upsert_property "${final}/config.properties" \
      experimental.reserved-pool-enabled false
    upsert_property "${final}/config.properties" experimental.spill-enabled true
    # Join spilling rejects broadcast joins ("A fixed distribution is required").
    upsert_property "${final}/config.properties" experimental.join-spill-enabled false
    upsert_property "${final}/config.properties" experimental.spiller-spill-path \
      /tmp/presto-spill
    python3 - "${final}/jvm.config" "${WORKER_MEMORY_LIMIT_GIB}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
heap = sys.argv[2]
lines = path.read_text().splitlines()
lines = [
    f"-Xmx{heap}G" if line.startswith("-Xmx") else
    f"-Xms{heap}G" if line.startswith("-Xms") else line
    for line in lines
]
path.write_text("\n".join(lines) + "\n")
PY
  fi
  set_property "${final}/node.properties" node.id \
    "aws-${RUN_ID}-worker-${WORKER_INDEX}"
fi

cp -a "${final}/." "${assembled}/"
find "${base}" -type f -print0 | sort -z | xargs -0 sha256sum \
  >"${runtime_root}/base_config_${ROLE}.sha256"
find "${final}" -type f -print0 | sort -z | xargs -0 sha256sum \
  >"${runtime_root}/final_config_${ROLE}.sha256"
diff -ru "${base}" "${final}" >"${runtime_root}/config_${ROLE}.diff" || true
tuning_id=$(
  printf '%s\n' \
    "drivers=${TASK_MAX_DRIVERS_PER_TASK}" \
    "split=${HIVE_MAX_SPLIT_SIZE}" \
    "loader=${HIVE_SPLIT_LOADER_CONCURRENCY}" \
    "dynamic_filtering=${DYNAMIC_FILTERING_ENABLED}" \
    "exchange_tuning=${CPU_EXCHANGE_TUNING_ENABLED}" |
    sha256sum | cut -c1-12
)
history="${runtime_root}/config_history/${tuning_id}/${ROLE}"
rm -rf "${history}"
mkdir -p "${history}"
cp -a "${final}/." "${history}/"
cat >"${history}/tuning.json" <<EOF
{
  "task_max_drivers_per_task": ${TASK_MAX_DRIVERS_PER_TASK},
  "hive_max_split_size": "${HIVE_MAX_SPLIT_SIZE}",
  "hive_split_loader_concurrency": ${HIVE_SPLIT_LOADER_CONCURRENCY},
  "dynamic_filtering_enabled": ${DYNAMIC_FILTERING_ENABLED},
  "cpu_exchange_tuning_enabled": ${CPU_EXCHANGE_TUNING_ENABLED}
}
EOF

docker rm -f presto-coordinator presto-native-worker-cpu presto-native-worker-gpu presto-java-worker trino-worker 2>/dev/null || true
timestamp=$(date -u +%Y%m%dT%H%M%SZ)

if [[ ${ROLE} == coordinator ]]; then
  docker run -d \
    --name presto-coordinator \
    --network host \
    --restart no \
    -e "AWS_DEFAULT_REGION=${AWS_REGION}" \
    -e "AWS_REGION=${AWS_REGION}" \
    -e "SERVER_START_TIMESTAMP=${timestamp}" \
    -v "${assembled}:/opt/presto-server/etc:ro" \
    -v "${runtime_root}/metastore:/var/lib/presto/data/hive/metastore" \
    -v "${runtime_root}/data:/var/lib/presto/data/local" \
    -v "${runtime_root}/logs:/opt/presto-server/logs" \
    -v "${repo}/presto/docker/launch_coordinator.sh:/opt/launch_coordinator.sh:ro" \
    --entrypoint bash \
    "${COORDINATOR_IMAGE}" \
    /opt/launch_coordinator.sh
else
  cache_mount_args=()
  if ((ASYNC_CACHE_SSD_GIB > 0)); then
    cache_mount_args=(-v /mnt/nvme:/mnt/nvme)
  fi
  worker_name=presto-native-worker-cpu
  worker_launcher="${repo}/presto/docker/launch_presto_servers.sh"
  gpu_args=()
  if [[ ${WORKER_ENGINE} == java ]]; then
    worker_name=presto-java-worker
    worker_launcher="${repo}/presto/docker/launch_java_worker.sh"
  elif [[ ${WORKER_ENGINE} == gpu ]]; then
    worker_name=presto-native-worker-gpu
    worker_launcher="${repo}/presto/aws/ec2/remote/gpu_worker_entry.sh"
    # Host networking also exposes docker0 and other interfaces that peers cannot
    # reach, so UCX is restricted to the primary NIC. Over TCP, UCX must ask the
    # CUDA driver for each pointer's memory type (UCX_MEMTYPE_CACHE=n); otherwise
    # it treats RMM buffers as host memory and send() fails with EIO.
    nic=$(ip route get 8.8.8.8 | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')
    ucx_root=/opt/presto-ucx/1.22.0
    gpu_args=(
      --gpus all
      --shm-size 16g
      --ulimit memlock=-1
      -v "${repo}/presto/docker/launch_presto_servers.sh:/opt/launch_presto_servers.sh:ro"
      -e "GPU_S3_CREDENTIALS=${GPU_S3_CREDENTIALS:-none}"
      -e "GPU_NUMA_BIND=${GPU_NUMA_BIND:-true}"
      -e CUDA_VISIBLE_DEVICES=0
      -e "LD_LIBRARY_PATH=${ucx_root}/lib:${ucx_root}/lib/ucx:/usr/lib64/presto-native-libs:/usr/local/cuda/lib64:/usr/local/lib"
      -e "UCX_MODULE_DIR=${ucx_root}/lib/ucx"
      -e "UCX_TLS=${GPU_UCX_TLS:-tcp,cuda_copy}"
      -e "UCX_NET_DEVICES=${nic}"
      -e UCX_MEMTYPE_CACHE=n
      -e UCX_RNDV_FRAG_MEM_TYPES=host
      -e UCX_CUDA_COPY_DMABUF=no
      -e UCX_TCP_CM_REUSEADDR=y
      -e UCX_SOCKADDR_TLS_PRIORITY=tcp
      -e UCX_MAX_RNDV_RAILS=1
      -e UCX_RNDV_PIPELINE_ERROR_HANDLING=n
      -e UCX_KEEPALIVE_INTERVAL=1ms
      -e UCX_TCP_KEEPINTVL=1ms
      -e UCX_WARN_UNUSED_ENV_VARS=n
      -e UCX_LOG_LEVEL=info
      -e GLOG_logtostderr=1
      -e "KVIKIO_NTHREADS=${GPU_KVIKIO_NTHREADS:-64}"
      -e "LIBCUDF_KERNEL_CACHE_PATH=/var/lib/presto/data/local/libcudf-cache"
    )
  fi
  docker run -d \
    --name "${worker_name}" \
    --network host \
    --restart no \
    --cap-add SYS_NICE \
    -e "AWS_DEFAULT_REGION=${AWS_REGION}" \
    -e "AWS_REGION=${AWS_REGION}" \
    -e "SERVER_START_TIMESTAMP=${timestamp}" \
    -v "${assembled}:/opt/presto-server/etc:ro" \
    -v "${runtime_root}/metastore:/var/lib/presto/data/hive/metastore" \
    -v "${runtime_root}/data:/var/lib/presto/data/local" \
    -v "${runtime_root}/logs:/opt/presto-server/logs" \
    "${cache_mount_args[@]}" \
    "${gpu_args[@]}" \
    -v "${worker_launcher}:/opt/launch_worker.sh:ro" \
    --entrypoint bash \
    "${WORKER_IMAGE}" \
    /opt/launch_worker.sh
fi

if [[ -f ${runtime_root}/telemetry/${ROLE}.sampler.pid ]]; then
  kill "$(cat "${runtime_root}/telemetry/${ROLE}.sampler.pid")" 2>/dev/null || true
fi
nohup bash "${repo}/presto/aws/ec2/remote/sample_host.sh" \
  "${ROLE}" "${runtime_root}/telemetry/${ROLE}.jsonl" \
  >"${runtime_root}/telemetry/${ROLE}.sampler.log" 2>&1 &
echo "$!" >"${runtime_root}/telemetry/${ROLE}.sampler.pid"

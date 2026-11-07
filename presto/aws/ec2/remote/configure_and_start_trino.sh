#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Trino counterpart of configure_and_start.sh. Both roles run the Trino image
# (COORDINATOR_IMAGE on the coordinator, WORKER_IMAGE on workers). The Hive
# catalog reads a Trino file metastore from TRINO_METASTORE_S3_URI.

set -euo pipefail

required=(
  RUN_ID ROLE WORKER_COUNT COORDINATOR_ADDRESS AWS_REGION
  HIVE_MAX_SPLIT_SIZE HIVE_SPLIT_LOADER_CONCURRENCY DYNAMIC_FILTERING_ENABLED
  COORDINATOR_HEAP_GIB COORDINATOR_HEADROOM_GIB
  COORDINATOR_QUERY_MEMORY_PER_NODE_GIB WORKER_QUERY_MEMORY_GIB
  WORKER_MEMORY_LIMIT_GIB COORDINATOR_IMAGE WORKER_IMAGE TRINO_METASTORE_S3_URI
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "missing required environment variable: ${name}" >&2
    exit 2
  fi
done
if [[ ${ROLE} == worker && -z ${WORKER_INDEX:-} ]]; then
  echo "WORKER_INDEX is required for worker role" >&2
  exit 2
fi

runtime_root=/opt/presto-aws
final="${runtime_root}/final_config/${ROLE}"
rm -rf "${final}" "${runtime_root}/runtime_etc"
mkdir -p "${final}/catalog" "${runtime_root}/trino-data" "${runtime_root}/logs" "${runtime_root}/telemetry"

if [[ ${ROLE} == coordinator ]]; then
  heap=${COORDINATOR_HEAP_GIB}
  node_id="aws-${RUN_ID}-coordinator"
  image=${COORDINATOR_IMAGE}
  cat >"${final}/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=8080
discovery.uri=http://${COORDINATOR_ADDRESS}:8080
protocol.v1.alternate-header-name=Presto
query.max-memory=$((WORKER_QUERY_MEMORY_GIB * WORKER_COUNT))GB
query.max-memory-per-node=${COORDINATOR_QUERY_MEMORY_PER_NODE_GIB}GB
memory.heap-headroom-per-node=${COORDINATOR_HEADROOM_GIB}GB
query-manager.required-workers=${WORKER_COUNT}
query-manager.required-workers-max-wait=10m
enable-dynamic-filtering=${DYNAMIC_FILTERING_ENABLED}
EOF
else
  heap=${WORKER_MEMORY_LIMIT_GIB}
  node_id="aws-${RUN_ID}-worker-${WORKER_INDEX}"
  image=${WORKER_IMAGE}
  cat >"${final}/config.properties" <<EOF
coordinator=false
http-server.http.port=8080
discovery.uri=http://${COORDINATOR_ADDRESS}:8080
protocol.v1.alternate-header-name=Presto
query.max-memory-per-node=${WORKER_QUERY_MEMORY_GIB}GB
memory.heap-headroom-per-node=$((heap - WORKER_QUERY_MEMORY_GIB - 2))GB
enable-dynamic-filtering=${DYNAMIC_FILTERING_ENABLED}
EOF
fi

cat >"${final}/node.properties" <<EOF
node.environment=production
node.id=${node_id}
node.data-dir=/data/trino
EOF

cat >"${final}/jvm.config" <<EOF
-server
-Xmx${heap}G
-Xms${heap}G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+ExplicitGCInvokesConcurrent
-XX:+ExitOnOutOfMemoryError
-XX:+HeapDumpOnOutOfMemoryError
-XX:-OmitStackTraceInFastThrow
-XX:ReservedCodeCacheSize=512M
-XX:PerMethodRecompilationCutoff=10000
-XX:PerBytecodeRecompilationCutoff=10000
-XX:+EnableDynamicAgentLoading
-Djdk.attach.allowAttachSelf=true
-Djdk.nio.maxCachedBufferSize=2000000
-Dfile.encoding=UTF-8
EOF

cat >"${final}/catalog/hive.properties" <<EOF
connector.name=hive
hive.metastore=file
hive.metastore.catalog.dir=${TRINO_METASTORE_S3_URI}
hive.metastore.disable-location-checks=true
fs.native-s3.enabled=true
s3.region=${AWS_REGION}
hive.max-split-size=${HIVE_MAX_SPLIT_SIZE}
hive.split-loader-concurrency=${HIVE_SPLIT_LOADER_CONCURRENCY}
EOF

cp -a "${final}/." "${runtime_root}/runtime_etc/"
chown -R 1000:1000 "${runtime_root}/runtime_etc" "${runtime_root}/trino-data"
find "${final}" -type f -print0 | sort -z | xargs -0 sha256sum \
  >"${runtime_root}/final_config_${ROLE}.sha256"

docker rm -f presto-coordinator presto-native-worker-cpu presto-java-worker trino-worker 2>/dev/null || true
name=trino-worker
if [[ ${ROLE} == coordinator ]]; then
  name=presto-coordinator
fi
docker run -d \
  --name "${name}" \
  --network host \
  --restart no \
  --ulimit nofile=131072:131072 \
  -e "AWS_DEFAULT_REGION=${AWS_REGION}" \
  -e "AWS_REGION=${AWS_REGION}" \
  -v "${runtime_root}/runtime_etc:/etc/trino:ro" \
  -v "${runtime_root}/trino-data:/data/trino" \
  "${image}"

if [[ -f ${runtime_root}/telemetry/${ROLE}.sampler.pid ]]; then
  kill "$(cat "${runtime_root}/telemetry/${ROLE}.sampler.pid")" 2>/dev/null || true
fi
nohup bash /opt/velox-testing/presto/aws/ec2/remote/sample_host.sh \
  "${ROLE}" "${runtime_root}/telemetry/${ROLE}.jsonl" \
  >"${runtime_root}/telemetry/${ROLE}.sampler.log" 2>&1 &
echo "$!" >"${runtime_root}/telemetry/${ROLE}.sampler.pid"

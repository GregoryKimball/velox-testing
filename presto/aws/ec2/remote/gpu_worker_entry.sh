#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Entry point of the single-GPU Presto native worker container.
#
# GPU_S3_CREDENTIALS=imds: KvikIO's direct S3 reads (cudf.hive.use-buffered-input=false)
# take credentials only from the environment, so load the instance role's
# credentials from instance metadata inside the container. Nothing is passed in
# from outside; the credentials expire with the instance role session.
#
# GPU_NUMA_BIND=false: start presto_server without numactl. Binding memory with
# numactl makes the cuDF pinned host staging arena fail to initialize.

set -euo pipefail
ldconfig

: "${SERVER_START_TIMESTAMP:?SERVER_START_TIMESTAMP must be set}"
logs=/opt/presto-server/logs
mkdir -p "${logs}"

if [[ ${GPU_S3_CREDENTIALS:-none} == imds ]]; then
  imds=http://169.254.169.254/latest
  token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' "${imds}/api/token")
  role=$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "${imds}/meta-data/iam/security-credentials/")
  document=$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
    "${imds}/meta-data/iam/security-credentials/${role}")
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"${document}")
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"${document}")
  AWS_SESSION_TOKEN=$(jq -r .Token <<<"${document}")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "instance role ${role} credentials expire $(jq -r .Expiration <<<"${document}")"
fi

if [[ ${GPU_NUMA_BIND:-true} == true ]]; then
  exec bash /opt/launch_presto_servers.sh
fi
log_file="${logs}/worker_0_${SERVER_START_TIMESTAMP}.log"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader >"${log_file}"
exec presto_server --etc-dir=/opt/presto-server/etc/ >>"${log_file}" 2>&1

#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ $# -ne 4 && $# -ne 6 ]]; then
  echo "usage: bootstrap_node.sh <role> <coordinator-image> <worker-image> <metastore-s3-uri>" \
    "[<coordinator-image-s3-uri|-> <worker-image-s3-uri|->]" >&2
  exit 2
fi

role=$1
coordinator_image=$2
worker_image=$3
metastore_uri=$4
coordinator_image_uri=${5:--}
worker_image_uri=${6:--}
runtime_root=/opt/presto-aws

if [[ ${role} != coordinator && ${role} != worker ]]; then
  echo "role must be coordinator or worker" >&2
  exit 2
fi

mkdir -p \
  "${runtime_root}/base_config" \
  "${runtime_root}/final_config" \
  "${runtime_root}/logs" \
  "${runtime_root}/metastore" \
  "${runtime_root}/results" \
  "${runtime_root}/telemetry"

python3 -m venv "${runtime_root}/venv"
"${runtime_root}/venv/bin/pip" install --disable-pip-version-check \
  -r /opt/velox-testing/presto/testing/requirements.txt

# An image archive (docker save | zstd) is loaded instead of pulled; the image
# reference is then a local tag that the archive must provide.
fetch_image() {
  local image=$1 uri=$2
  if [[ ${uri} == - ]]; then
    docker pull "${image}"
  elif ! docker image inspect "${image}" >/dev/null 2>&1; then
    aws s3 cp "${uri}" - --only-show-errors | zstd -dc | docker load
    docker image inspect "${image}" >/dev/null
  fi
}

if [[ ${role} == coordinator ]]; then
  fetch_image "${coordinator_image}" "${coordinator_image_uri}"
  local_image=${coordinator_image}
else
  fetch_image "${worker_image}" "${worker_image_uri}"
  local_image=${worker_image}
fi

aws s3 sync "${metastore_uri}" "${runtime_root}/metastore/" --only-show-errors

token=$(curl -fsS -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
  http://169.254.169.254/latest/api/token)
role_name=$(curl -fsS \
  -H "X-aws-ec2-metadata-token: ${token}" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/)
credential_document=$(curl -fsS \
  -H "X-aws-ec2-metadata-token: ${token}" \
  "http://169.254.169.254/latest/meta-data/iam/security-credentials/${role_name}")
credential_code=$(jq -r .Code <<<"${credential_document}")
if [[ "${credential_code}" != "Success" ]]; then
  echo "instance-profile credential probe failed: ${credential_code}" >&2
  exit 1
fi

aws sts get-caller-identity >/dev/null

cat >"${runtime_root}/bootstrap_info.json" <<EOF
{
  "coordinator_image": "${coordinator_image}",
  "worker_image": "${worker_image}",
  "role": "${role}",
  "local_image_id": "$(docker image inspect --format '{{.Id}}' "${local_image}")",
  "iam_role": "${role_name}",
  "credential_expiration": "$(jq -r .Expiration <<<"${credential_document}")",
  "metastore_uri": "${metastore_uri}",
  "bootstrapped_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

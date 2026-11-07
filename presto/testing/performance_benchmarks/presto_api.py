# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

"""Shared HTTP and Presto REST API helpers."""

from typing import Any

import requests

# Trino rejects REST calls without a user; Presto ignores the header.
HEADERS = {"X-Trino-User": "benchmark", "X-Presto-User": "benchmark"}


def fetch_json(url: str, timeout: int = 10) -> Any | None:
    """Fetch JSON from a URL, returning None on error."""
    try:
        response = requests.get(url, timeout=timeout, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Warning: Failed to fetch {url}: {e}")
        return None


def fetch_text(url: str, timeout: int = 10) -> str | None:
    """Fetch text from a URL, returning None on error."""
    try:
        response = requests.get(url, timeout=timeout, headers=HEADERS)
        response.raise_for_status()
        return response.text
    except Exception as e:
        print(f"Warning: Failed to fetch {url}: {e}")
        return None


def get_cluster_tag(hostname: str, port: int) -> str | None:
    """Fetch the cluster-tag from the coordinator's /v1/cluster endpoint.

    Returns the tag string (e.g. 'native-gpu', 'native-cpu', 'java'),
    or None if the endpoint is unavailable or the tag is not set.
    """
    url = f"http://{hostname}:{port}/v1/cluster"
    data = fetch_json(url)
    if data is None or not isinstance(data, dict):
        return None
    tag = data.get("clusterTag")
    if not tag or not isinstance(tag, str):
        return None
    return tag


def is_trino(hostname: str, port: int) -> bool:
    """Trino serves /v1/info but has no /v1/node endpoint."""
    try:
        info = requests.get(f"http://{hostname}:{port}/v1/info", timeout=10, headers=HEADERS)
        node = requests.get(f"http://{hostname}:{port}/v1/node", timeout=10, headers=HEADERS)
    except Exception:
        return False
    return info.ok and node.status_code == 404


def get_nodes(hostname: str, port: int) -> list | None:
    """Fetch the worker node list from Presto's /v1/node endpoint.

    Returns the list of node dicts, or None on failure.
    """
    url = f"http://{hostname}:{port}/v1/node"
    raw = fetch_json(url)
    if raw is None:
        return None
    if not isinstance(raw, list):
        return None
    return raw

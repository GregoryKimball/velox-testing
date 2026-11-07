#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

"""Write the distributed plan of every TPC-H query to <output-dir>.

usage: explain_plans.py <coordinator> <catalog> <schema> <output-dir> [--analyze]

Each query gets <Qn>.txt (EXPLAIN (TYPE DISTRIBUTED)) and, when the engine
supports it, <Qn>.json (FORMAT JSON). With --analyze, <Qn>.analyze.txt holds
EXPLAIN ANALYZE output, which executes the query.
"""

import json
import sys
from pathlib import Path

import prestodb

QUERIES = Path("/opt/velox-testing/common/testing/queries/tpch/queries.json")


def explain(cursor, statement: str) -> str:
    cursor.execute(statement)
    return "\n".join(row[0] for row in cursor.fetchall())


def main() -> int:
    coordinator, catalog, schema, output = sys.argv[1:5]
    analyze = "--analyze" in sys.argv[5:]
    output_dir = Path(output)
    output_dir.mkdir(parents=True, exist_ok=True)
    connection = prestodb.dbapi.connect(host=coordinator, port=8080, user="explain", catalog=catalog, schema=schema)
    cursor = connection.cursor()
    cursor.execute("SELECT node_version FROM system.runtime.nodes WHERE coordinator")
    (version,) = cursor.fetchone()
    summary = {"coordinator_version": version, "catalog": catalog, "schema": schema, "queries": {}}
    for name, sql in json.loads(QUERIES.read_text()).items():
        entry = summary["queries"].setdefault(name, {})
        try:
            (output_dir / f"{name}.txt").write_text(explain(cursor, f"EXPLAIN (TYPE DISTRIBUTED) {sql}"))
            entry["text"] = "ok"
        except Exception as error:
            entry["text"] = f"error: {error}"
        try:
            (output_dir / f"{name}.json").write_text(explain(cursor, f"EXPLAIN (TYPE DISTRIBUTED, FORMAT JSON) {sql}"))
            entry["json"] = "ok"
        except Exception as error:
            entry["json"] = f"error: {error}"
        if analyze:
            try:
                (output_dir / f"{name}.analyze.txt").write_text(explain(cursor, f"EXPLAIN ANALYZE {sql}"))
                entry["analyze"] = "ok"
            except Exception as error:
                entry["analyze"] = f"error: {error}"
        print(name, entry, flush=True)
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

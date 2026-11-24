#!/usr/bin/env python3
"""Summarizes the benchmark raw data into results/summary.md and summary.csv."""

import csv
import json
import re
import statistics
from datetime import datetime
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"

UPLOAD_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d+[+-]\d{4} .*\[backup/([^\]]+)\] "
    r"uploading (data|journals)( done)?$"
)


def upload_phase_seconds(name):
    """Returns the upload phase duration (data + journals) from the agent log."""
    start = None
    end = None
    for line in (RESULTS / "agent.log").read_text(errors="replace").splitlines():
        m = UPLOAD_RE.match(line)
        if not m or m.group(2) != name:
            continue
        ts, _, phase, done = m.groups()
        if phase == "data" and not done and start is None:
            start = ts
        elif phase == "journals" and done:
            end = ts
    if start is None or end is None:
        return None

    fmt = "%Y-%m-%dT%H:%M:%S"
    return (datetime.strptime(end, fmt) - datetime.strptime(start, fmt)).total_seconds()



def read_runs():
    runs = []
    for line in (RESULTS / "runs.tsv").read_text().splitlines():
        if not line.strip():
            continue
        cap, name, start, end, size, size_uncompressed = line.split("\t")
        runs.append(
            {
                "cap": int(cap),
                "name": name,
                "start": int(start),
                "end": int(end),
                "size": int(size),
                "size_uncompressed": int(size_uncompressed),
            }
        )
    return runs


def read_load():
    rows = []
    for line in (RESULTS / "load.jsonl").read_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        rows.append(json.loads(line))
    return rows


def read_metrics():
    rows = []
    lines = (RESULTS / "metrics.tsv").read_text().splitlines()
    for line in lines[1:]:
        ts, dbpath, rx, ticks, rss = line.split("\t")
        rows.append(
            {
                "ts": int(ts),
                "dbpath": int(dbpath),
                "rx": int(rx),
                "ticks": int(ticks),
                "rss": int(rss),
            }
        )
    return rows


def window(rows, start, end):
    return [r for r in rows if start <= r["ts"] <= end]


def load_stats(rows):
    if not rows:
        return {"p95": 0.0, "p99": 0.0, "p99_max": 0.0, "ops": 0.0}
    return {
        "p95": statistics.median(r["p95"] for r in rows),
        "p99": statistics.median(r["p99"] for r in rows),
        "p99_max": max(r["p99"] for r in rows),
        "ops": sum(r["ops"] for r in rows) / max(1, len(rows)),
    }


def main():
    runs = read_runs()
    load = read_load()
    metrics = read_metrics()

    # The harness lets the workload warm up for 25 s before the first backup,
    # so the first 5-20 s of load are a clean, backup-free baseline.
    load_start = load[0]["ts"] if load else 0
    baseline = load_stats(window(load, load_start + 5000, load_start + 20000))

    header = (
        "| Cap (MiB/s) | Backup (MiB) | Duration (s) | Upload phase (s) | "
        "Upload (MiB/s) | Wire on lo (MiB/s) | DB p95 med (ms) | DB p99 med (ms) | "
        "DB p99 max (ms) | Ops/s | dbPath growth (MiB) |"
    )
    sep = "|" + "---|" * 11
    lines = [
        "# PBM physical backup rate-limit benchmark",
        "",
        f"Baseline (no backup): p95={baseline['p95']:.2f} ms, "
        f"p99={baseline['p99']:.2f} ms, p99 max={baseline['p99_max']:.2f} ms, "
        f"~{baseline['ops']:.0f} ops/s",
        "",
        header,
        sep,
    ]

    csv_rows = []
    for run in runs:
        duration = (run["end"] - run["start"]) / 1000
        mib = run["size"] / (1024 * 1024)

        load_window = window(load, run["start"], run["end"])
        stats = load_stats(load_window)

        metric_window = window(metrics, run["start"], run["end"])
        if metric_window:
            growth = (max(m["dbpath"] for m in metric_window) - min(m["dbpath"] for m in metric_window)) / (
                1024 * 1024
            )
            wire = (
                (max(m["rx"] for m in metric_window) - min(m["rx"] for m in metric_window))
                / (1024 * 1024)
                / duration
            )
            # /proc/<pid>/stat fields 14+15 are in USER_HZ (100 on Linux).
            agent_ticks = max(m["ticks"] for m in metric_window) - min(m["ticks"] for m in metric_window)
            agent_cpu = agent_ticks / 100 / duration * 100 if duration else 0
            agent_rss = max(m["rss"] for m in metric_window) / 1024
        else:
            growth = 0.0
            wire = 0.0
            agent_cpu = 0.0
            agent_rss = 0.0

        cap_label = "none" if run["cap"] == 0 else str(run["cap"])
        upload_s = upload_phase_seconds(run["name"])
        upload_rate = mib / upload_s if upload_s else 0
        lines.append(
            f"| {cap_label} | {mib:.1f} | {duration:.2f} | "
            f"{upload_s if upload_s is not None else 0:.0f} | {upload_rate:.1f} | {wire:.1f} | "
            f"{stats['p95']:.2f} | {stats['p99']:.2f} | {stats['p99_max']:.2f} | "
            f"{stats['ops']:.0f} | {growth:.1f} |"
        )
        csv_rows.append(
            {
                "cap_mib_s": cap_label,
                "backup_mib": round(mib, 1),
                "duration_s": round(duration, 2),
                "upload_phase_s": round(upload_s, 0) if upload_s is not None else None,
                "upload_mib_s": round(upload_rate, 1),
                "wire_lo_mib_s": round(wire, 1),
                "db_p95_median_ms": round(stats["p95"], 2),
                "db_p99_median_ms": round(stats["p99"], 2),
                "db_p99_max_ms": round(stats["p99_max"], 2),
                "ops_per_s": round(stats["ops"]),
                "dbpath_growth_mib": round(growth, 1),
                "agent_cpu_pct": round(agent_cpu, 1),
                "agent_rss_max_mib": round(agent_rss, 1),
            }
        )

    resource_lines = [
        "",
        "## Agent resource use",
        "",
        "| Cap (MiB/s) | Agent CPU (% of one core) | Agent max RSS (MiB) |",
        "|---|---|---|",
    ]
    for row in csv_rows:
        resource_lines.append(
            f"| {row['cap_mib_s']} | {row['agent_cpu_pct']:.1f} | {row['agent_rss_max_mib']:.1f} |"
        )

    lines.extend(resource_lines)

    (RESULTS / "summary.md").write_text("\n".join(lines) + "\n")

    with (RESULTS / "summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=csv_rows[0].keys())
        writer.writeheader()
        writer.writerows(csv_rows)

    print("\n".join(lines))


if __name__ == "__main__":
    main()

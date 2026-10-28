#!/usr/bin/env python3
"""汇总 --frame-trace 捕获，导出最大帧及前后文；span 为墙钟区间，允许嵌套。"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path


def interval_union(intervals):
    end = None
    total = 0
    for start, stop in sorted(intervals):
        if end is None or start > end:
            total += stop - start
        else:
            total += max(0, stop - end)
        end = max(end or stop, stop)
    return total


def quantile(values, fraction):
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * fraction)] if ordered else 0


def frame_cost(row):
    spans = row["spans"]
    stages = Counter()
    for label, start, stop in spans:
        stages[label] += stop - start
    covered = interval_union((a, b) for label, a, b in spans
                             if label in {"physics_nodes", "idle_nodes", "render_submit"})
    return {"frame": row["frame"], "interval_ms": row["interval_us"] / 1000,
            "start_us": row["start_us"], "end_us": row["end_us"],
            "outer_covered_ms": covered / 1000,
            "outside_outer_spans_ms": (row["interval_us"] - covered) / 1000,
            "stages_ms": {k: v / 1000 for k, v in stages.items()},
            "counts": row["counts"], "observer_ms": row["observer_us"] / 1000,
            "context": row["context"],
            "events": [item for item in row["events"] if item[0] != "packet"]}


def analyze(path, output, bounds, top, threshold):
    frames = []
    header = None
    footer = None
    with path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            row = json.loads(line)
            if row["event"] == "trace_start": header = row
            elif row["event"] == "trace_end": footer = row
            elif row["event"] == "frame":
                row["_line"] = number
                frames.append(row)
    if not header:
        raise ValueError(f"missing trace_start: {path}")
    offset = header["unix_us"] / 1e6 - header["mono_us"] / 1e6
    selected = [row for row in frames if not row.get("partial") and
                (bounds is None or bounds[0] <= offset + row["start_us"] / 1e6 and
                 offset + row["end_us"] / 1e6 <= bounds[1])]
    indexes = {row["frame"]: index for index, row in enumerate(frames)}
    worst = sorted(selected, key=lambda row: row["interval_us"], reverse=True)[:top]
    all_stages = Counter()
    all_counts = Counter()
    packet_count = 0
    packet_bytes = 0
    cli_launch = []
    cli_enqueue = []
    background_launch = []
    for row in selected:
        for label, start, stop in row["spans"]:
            all_stages[label] += stop - start
            if label == "cli_launch": cli_launch.append(stop - start)
            if label == "cli_enqueue": cli_enqueue.append(stop - start)
        all_counts.update(row["counts"])
        for item in row["events"]:
            if item[0] == "packet":
                packet_count += 1
                # base64 长度可有两个填充字符，精确值无需在分析时解码大块数据。
                packet_bytes += len(item[2]["bytes_b64"]) * 3 // 4 - item[2]["bytes_b64"].count("=")
            elif item[0] == "cli_result" and item[2].get("thread") == "cli_worker":
                background_launch.append(item[2]["launch_us"])
    summary = {"trace": str(path), "frames": len(selected), "complete": footer is not None,
               "file_bytes": path.stat().st_size, "threshold_ms": threshold,
               "over_threshold": sum(row["interval_us"] >= threshold * 1000 for row in selected),
               "over_30ms": sum(row["interval_us"] >= 30000 for row in selected),
               "over_50ms": sum(row["interval_us"] >= 50000 for row in selected),
               "interval_ms": {str(q): quantile([r["interval_us"] / 1000 for r in selected], q)
                               for q in (0.5, 0.95, 0.99, 1.0)},
               "observer_ms": {str(q): quantile([r["observer_us"] / 1000 for r in selected], q)
                               for q in (0.5, 0.99, 1.0)},
               "observer_mean_ms": sum(r["observer_us"] / 1000 for r in selected) / max(len(selected), 1),
               "dropped_frames": footer["writer"][1] if footer else None,
               "writer_encode_batch_max_ms": footer["writer"][2] / 1000 if footer else None,
               "writer_io_batch_max_ms": footer["writer"][3] / 1000 if footer else None,
               "counts": dict(all_counts), "packets": packet_count, "packet_bytes": packet_bytes,
               "cli": {"main_launch_calls": len(cli_launch), "main_launch_max_ms": max(cli_launch, default=0) / 1000,
                       "enqueue_calls": len(cli_enqueue), "enqueue_max_ms": max(cli_enqueue, default=0) / 1000,
                       "worker_completions": len(background_launch), "worker_launch_max_ms": max(background_launch, default=0) / 1000},
               "stages_total_ms": {k: v / 1000 for k, v in all_stages.items()},
               "worst": []}
    label = path.parent.parent.name
    for rank, row in enumerate(worst, 1):
        index = indexes[row["frame"]]
        context = frames[max(0, index - 4):index + 5]
        dest = output / f"{label}-peak{rank}-frame{row['frame']}.json"
        cost = frame_cost(row)
        cost.update(utc_end=datetime.fromtimestamp(offset + row["end_us"] / 1e6, timezone.utc).isoformat(),
                    line=row["_line"], context_file=str(dest))
        dest.write_text(json.dumps({"source": str(path), "header": header, "peak": cost,
                                    "frames": context}, ensure_ascii=False, indent=2), encoding="utf-8")
        summary["worst"].append(cost)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="对局目录或单个 .frames.jsonl")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--battle-only", action="store_true", help="从同场 server 日志提取正式战斗边界")
    parser.add_argument("--top", type=int, default=3)
    parser.add_argument("--threshold-ms", type=float, default=25)
    args = parser.parse_args()
    paths = [args.capture] if args.capture.is_file() else sorted(args.capture.glob("*/diagnostics/*.frames.jsonl"))
    if not paths: parser.error("没有帧记录文件")
    output = args.output or (args.capture.parent if args.capture.is_file() else args.capture) / "frame_analysis"
    output.mkdir(parents=True, exist_ok=True)
    bounds = None
    if args.battle_only:
        root = args.capture if args.capture.is_dir() else args.capture.parents[2]
        rounds = []
        for log in (root / "server/diagnostics").glob("server-*.log"):
            with log.open(encoding="utf-8") as stream:
                for line in stream:
                    row = json.loads(line)
                    if row["event"] == "round_state": rounds.append(row)
        bounds = (min(datetime.fromisoformat(r["time"].replace("Z", "+00:00")).timestamp()
                      for r in rounds if r["data"]["state"] == 1),
                  max(datetime.fromisoformat(r["time"].replace("Z", "+00:00")).timestamp()
                      for r in rounds if r["data"]["state"] == 3))
    results = [analyze(path.resolve(), output.resolve(), bounds, args.top, args.threshold_ms) for path in paths]
    result = {"battle_unix_bounds": bounds, "captures": results,
              "interpretation": "inclusive wall-clock spans; outside_outer_spans includes engine work, frame pacing and OS scheduling; observer_us is a measured subset, not a complete A/B overhead estimate"}
    (output / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(output), "captures": [{k: row[k] for k in (
        "trace", "frames", "interval_ms", "over_30ms", "over_50ms", "observer_ms", "dropped_frames", "packets")}
        for row in results]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

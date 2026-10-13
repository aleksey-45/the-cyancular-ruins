#!/usr/bin/env python3
"""Run real ENet matches across fluctuating RTT/loss profiles."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import sys
from network_link import PROFILES, quantiles, traffic_rates

ROOT = Path(__file__).resolve().parents[2]


def summarize_network(case):
    measurement = case.get("network_sample")
    if not measurement:
        return None
    server = measurement["server"]
    valid, excluded = [], []
    for client in case["clients"]:
        sample = client.get("network_sample")
        reasons = []
        if case["failures"]: reasons.append("run_failed")
        if server is None: reasons.append("server_sample_missing")
        elif server["max_frame_ms"] > 50: reasons.append("server_long_frame")
        if sample is None:
            reasons.append("client_sample_missing")
        else:
            if not sample["complete"] or sample["observed_seconds"] < sample["end"]-sample["start"]-0.1:
                reasons.append("incomplete_window")
            if sample["max_frame_ms"] > 50: reasons.append("client_long_frame")
            if sample["baseline_changes"]: reasons.append("baseline_changed")
            if sample["outage_seconds"]: reasons.append("disconnected")
        if reasons: excluded.append({"index":client["index"], "reasons":reasons})
        else: valid.append(sample)
    seconds = sum(s["observed_seconds"] for s in valid)
    stalls = sum(s["stall_seconds"] for s in valid)
    return {"valid_clients":len(valid), "expected_clients":case["count"], "excluded":excluded,
            "observed_seconds":seconds, "stall_seconds":stalls,
            "stall_fraction":stalls/seconds if seconds else None,
            "longest_stall_seconds":max((s["longest_stall_seconds"] for s in valid), default=None),
            "server_max_frame_ms":server["max_frame_ms"] if server else None,
            "client_max_frame_ms":[c["network_sample"]["max_frame_ms"] for c in case["clients"] if "network_sample" in c],
            "input_missing_fraction":server["input_missing_ticks"]/server["input_ticks"] if server and server["input_ticks"] and len(valid) == case["count"] else None,
            "state_gap_ms":quantiles([g for s in valid for g in s["state_gaps_ms"]]) if valid else None,
            "ping_ms":quantiles([p for s in valid for p in s["ping_ms"]]) if valid else None}



def summarize(case):
    settings = (case.get("network_sample") or {}).get("settings")
    duration = settings["end"]-settings["start"] if settings else case["elapsed_seconds"]
    traffic = {"server_upload":[], "server_download":[]}
    for link in case["links"]:
        for direction in link["directions"]:
            key = "server_upload" if direction["direction"] == "downlink" else "server_download"
            traffic[key].extend((link["started_wall_seconds"]+t,size) for t,size in direction["packet_trace"]
                                if not settings or settings["start"] <= link["started_wall_seconds"]+t < settings["end"])
    return {"count":case["count"], "profile":case["profile"], "seed":case["seed"],
            "bandwidth_kbps":case["bandwidth_kbps"], "fixed_throttle":case["fixed_throttle"],
            "failures":case["failures"], "stop_reason":case["stop_reason"],
            "elapsed_seconds":case["elapsed_seconds"], "network":summarize_network(case),
            "sender_offered_ipv4_kbps":{key:traffic_rates(packets,duration) for key,packets in traffic.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--counts", nargs="+", type=int, choices=(2,6,8), default=[2,6,8])
    parser.add_argument("--profiles", nargs="+", choices=tuple(PROFILES), default=list(PROFILES))
    parser.add_argument("--seeds", nargs="+", type=int, default=[1000])
    parser.add_argument("--bandwidths", nargs="+", type=float, default=[0])
    parser.add_argument("--network-seconds", type=float, default=12)
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("--timeout", type=float, default=130)
    parser.add_argument("--fixed-throttle", action="store_true")
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT/".test_logs/network/tiers")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {"profiles":PROFILES, "transport":"native_enet", "rtt":"injected_propagation_round_trip",
                "network_seconds":args.network_seconds, "settle_seconds":args.settle_seconds,
                "frame_limit_ms":50, "fixed_throttle":args.fixed_throttle,
                "workload":"royale; indestructible arena, fixed rifle, health restored every server tick",
                "game_source":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
                "script_sha256":{name:hashlib.sha256((ROOT/"tests/network"/name).read_bytes()).hexdigest()
                                 for name in ("match_client.gd","match_server.gd","network_link.py","run_matches.py","run_matrix.py","arena.cyrm")}}
    rows = []
    for count,profile,seed,bandwidth in itertools.product(args.counts,args.profiles,args.seeds,args.bandwidths):
        folder = args.output/f"{count}_{profile}_{seed}_{bandwidth:g}kbps"
        folder.mkdir(parents=True,exist_ok=True)
        command = [sys.executable,"-X","utf8",str(ROOT/"tests/network/run_matches.py"),
                   "--godot",args.godot,"--count",str(count),"--profile",profile,"--seed",str(seed),
                   "--bandwidth-kbps",str(bandwidth),"--network-seconds",str(args.network_seconds),
                   "--settle-seconds",str(args.settle_seconds),"--timeout",str(args.timeout),
                   "--no-trace","--output",str(folder)]
        if args.drop: command.append("--drop")
        if args.fixed_throttle: command.append("--fixed-throttle")
        with (folder/"runner.log").open("w",encoding="utf-8") as log:
            process = subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
        case = json.loads((folder/"result.json").read_text(encoding="utf-8"))
        row = summarize(case)
        row.update(result=str(folder/"result.json"),exit=process.returncode)
        rows.append(row)
        (args.output/"summary.json").write_text(json.dumps({"metadata":metadata,"runs":rows},indent=2),encoding="utf-8")
        network = row["network"]
        print(f"MATRIX {len(rows)} {folder.name} exit={process.returncode} "
              f"failures={row['failures']} network={network}",flush=True)
    failed = sum(bool(row["failures"]) or row["exit"] != 0 for row in rows)
    print(f"MATRIX COMPLETE runs={len(rows)} passed={len(rows)-failed}",flush=True)
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())

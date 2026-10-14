#!/usr/bin/env python3
"""Run the actual room, authority world and shared match client in separate Godot processes."""
import argparse, json, os, socket, subprocess, sys, time
from pathlib import Path
from network_link import LagLink, PROFILES

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / ".test_logs/network"
LOGS.mkdir(parents=True, exist_ok=True)

def runtime_error(output):
    return any(marker in output for marker in ("SCRIPT ERROR", "MATCH CLIENT FAIL", "ERROR: Error calling method", "ERROR: Condition", "ERROR: Parameter", "ERROR: Unable to send"))

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--count", type=int, choices=(2, 6, 8), default=2)
    parser.add_argument("--rtt", type=int, default=0)
    parser.add_argument("--jitter", type=int, default=0)
    parser.add_argument("--loss", type=float, default=0)
    parser.add_argument("--profile", choices=tuple(PROFILES))
    parser.add_argument("--seed", type=int, default=1000)
    parser.add_argument("--bandwidth-kbps", type=float, default=0, help="每条双向链路的带宽上限，实际带宽在其 50%%–100%% 间波动")
    parser.add_argument("--queue-ms", type=float, default=100)
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--battle-seconds", type=float, default=6)
    parser.add_argument("--no-trace", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--stall", action="store_true", help="对战中双向积压 750 ms 后突发释放，再双向断流 250 ms")
    parser.add_argument("--none", action="store_true")
    parser.add_argument("--fixed-throttle", action="store_true", help="测试对照：双方 ENet throttle 固定为 32")
    parser.add_argument("--network-seconds", type=float, default=0, help="预热完成后的网络专用墙钟计量窗口")
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("--server", type=Path, help="用导出的正式服务端跑 1v1 两局获胜流程")
    args = parser.parse_args()
    args.godot = args.godot.replace("_console.exe", ".exe")  # 直接管理引擎进程，避免退出控制台包装器后留下子进程。
    if args.server and args.count != 2:
        parser.error("导出验证使用 1v1")
    if args.server and args.stall:
        parser.error("断流夹具使用编辑器服务端")
    mode = {2:"pvp", 6:"team", 8:"royale"}[args.count]
    if args.network_seconds:
        mode = "royale"
    port = free_port()
    processes, streams, links = [], [], []
    tag = f"{args.count}_{args.rtt}_{args.loss}_{'none' if args.none else 'zstd'}"
    if args.server: tag += "_exported"
    if args.stall: tag += "_stall"
    if args.profile: tag += f"_{args.profile}_{args.seed}_{args.bandwidth_kbps}kbps"
    folder = args.output or LOGS / tag
    folder.mkdir(parents=True, exist_ok=True)
    started_at = time.monotonic()
    def launch(name, scene, extra):
        env = os.environ.copy()
        for key, leaf in (("APPDATA","roaming"),("LOCALAPPDATA","local")):
            location = folder / name / leaf
            location.mkdir(parents=True, exist_ok=True)
            env[key] = str(location)
        if sys.platform == "darwin":
            profile = (folder / name / "profile").resolve()
            profile.mkdir(parents=True, exist_ok=True)
            env["HOME"] = str(profile)
        stream = (folder / (name + ".log")).open("w", encoding="utf-8")
        streams.append(stream)
        cmd = [args.godot, "--headless", "--path", str(ROOT), "--disable-crash-handler", scene, "--", *extra]
        if args.server and name == "server":
            cmd = [str(args.server.resolve()), "--headless", "--", "--server", *extra]
        if args.none: cmd.append("--none")
        proc = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                creationflags=0x08000000 if os.name == "nt" else 0)
        processes.append(proc)
        return proc
    try:
        launch("server", "res://tests/network/match_server.tscn", ["--port",str(port),
               "--battle-seconds", str(args.battle_seconds), *(["--no-trace"] if args.no_trace else []),
               *(["--fixed-throttle"] if args.fixed_throttle else []),
               *(["--network-seconds", str(args.network_seconds), "--settle-seconds", str(args.settle_seconds)] if args.network_seconds else []),
               *(["--stall"] if args.stall else [])])
        time.sleep(1)
        clients = []
        for index in range(args.count):
            conditions = dict(rtt=args.rtt, jitter=args.jitter, loss=args.loss, seed=args.seed+index,
                              profile=args.profile, bandwidth_kbps=args.bandwidth_kbps, queue_ms=args.queue_ms,
                              warmup=bool(args.network_seconds))
            link = LagLink(port, **conditions)
            links.append(link)
            extra = ["--port",str(link.port), "--index",str(index), "--count",str(args.count), "--mode",mode]
            if args.drop and index == 1: extra.append("--drop")
            if args.server: extra.append("--exported")
            if args.network_seconds: extra.append("--network-sample")
            clients.append(launch(f"client{index}", "res://tests/network/match_client.tscn", extra))
            time.sleep(0.1)
        deadline = time.monotonic() + (150 if args.server else args.timeout)
        disturbed = False
        stop_reason = "completed"
        sample_settings = None
        while any(client.poll() is None for client in clients) and time.monotonic() < deadline:
            if args.network_seconds and sample_settings is None:
                for line in (folder / "server.log").read_text(encoding="utf-8").splitlines():
                    if line.startswith("NETWORK SAMPLE SETTINGS ") and line.endswith("}"):
                        sample_settings = json.loads(line.removeprefix("NETWORK SAMPLE SETTINGS "))
                        for link in links: link.schedule(sample_settings["shape_start"], sample_settings["end"])
            if args.stall and not disturbed and "MATCH NETWORK WINDOW" in (folder / "server.log").read_text(encoding="utf-8"):
                for link in links: link.disturb()
                disturbed = True
            if any(runtime_error((folder / f"client{i}.log").read_text(encoding="utf-8", errors="replace")) for i in range(args.count)):
                stop_reason = "client_error"
                break
            if any(client.poll() not in (None, 0) for client in clients):
                stop_reason = "client_exit"
                break
            time.sleep(0.1)
        if stop_reason == "completed" and any(client.poll() is None for client in clients):
            stop_reason = "timeout"
        for stream in streams: stream.flush()
        failures = []
        for index, client in enumerate(clients):
            output = (folder / f"client{index}.log").read_text(encoding="utf-8")
            if client.poll() != 0 or "MATCH CLIENT OK" not in output or runtime_error(output) or "MATCH CLIENT FAIL" in output:
                failures.append(f"client{index}")
        server_output = (folder / "server.log").read_text(encoding="utf-8")
        if ("SERVER READY" if args.server else "MATCH SERVER OK") not in server_output or runtime_error(server_output):
            failures.append("server")
        if args.stall and (not disturbed or any(link.stalled_packets == 0 or link.blackout_packets == 0 for link in links)):
            failures.append("stall fixture")
        report = {"count":args.count, "rtt":args.rtt, "jitter":args.jitter, "loss":args.loss,
                  "fixed_throttle": args.fixed_throttle,
                  "drop":args.drop, "compression":"none" if args.none else "zstd", "failures":failures,
                  "stop_reason":stop_reason}
        report.update(profile=args.profile, seed=args.seed, bandwidth_kbps=args.bandwidth_kbps,
                      transport="enet",
                      queue_ms=args.queue_ms, elapsed_seconds=time.monotonic()-started_at,
                      links=[link.report() for link in links])
        if any(link.error for link in links):
            failures.append("link emulator")
        report["playback"] = [json.loads(output.rsplit("PLAYBACK METRICS ", 1)[1].splitlines()[0])
                              for output in ((folder / f"client{i}.log").read_text(encoding="utf-8") for i in range(args.count))
                              if "PLAYBACK METRICS " in output]
        report["clients"] = [json.loads(output.rsplit("NETWORK METRICS ", 1)[1].splitlines()[0])
                             for output in ((folder / f"client{i}.log").read_text(encoding="utf-8") for i in range(args.count))
                             if "NETWORK METRICS " in output]
        report["exits"] = [process.poll() for process in processes]
        report["sender_throttle"] = [json.loads(line.removeprefix("SEND THROTTLE "))
                                     for line in server_output.splitlines() if line.startswith("SEND THROTTLE ")]
        report["round_rebuild"] = [json.loads(line.removeprefix("ROUND REBUILD METRICS "))
                                   for line in server_output.splitlines() if line.startswith("ROUND REBUILD METRICS ")]
        if args.network_seconds:
            samples = [json.loads(line.removeprefix("NETWORK SAMPLE SERVER "))
                       for line in server_output.splitlines() if line.startswith("NETWORK SAMPLE SERVER ")]
            report["network_sample"] = {"settings": sample_settings, "server": samples[-1] if samples else None}
        if args.server: report["exported_server"] = str(args.server.resolve())
        if args.stall:
            report["stall"] = {"buffer_ms": 750, "blackout_ms": 250,
                               "packets": [{"buffered": link.stalled_packets, "lost": link.blackout_packets} for link in links]}
        (folder / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(("NETWORK RUN FAIL " if failures else "NETWORK RUN OK ") + json.dumps(
            {key:report[key] for key in ("count", "profile", "seed", "transport", "bandwidth_kbps", "failures", "elapsed_seconds")}), flush=True)
        return bool(failures)
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
        for proc in processes:
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        for stream in streams: stream.close()
        for link in links: link.close()

if __name__ == "__main__":
    raise SystemExit(main())

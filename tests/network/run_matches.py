#!/usr/bin/env python3
"""Run the actual room, authority world and shared match client in separate Godot processes."""
import argparse, copy, hashlib, itertools, json, os, secrets, socket, subprocess, sys, threading, time
from pathlib import Path
from network_link import LagLink, PROFILES, summarize

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / ".test_logs/network"
LOGS.mkdir(parents=True, exist_ok=True)

def runtime_error(output):
    return any(marker in output for marker in ("SCRIPT ERROR", "MATCH CLIENT FAIL", "MATCH SERVER FAIL", "ERROR: Error calling method", "ERROR: Condition", "ERROR: Parameter", "ERROR: Unable to send"))

def free_port(kind=socket.SOCK_DGRAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def arguments():
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
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--battle-seconds", type=float, default=24, help="大乱斗的实际对战时长，最后三秒停止输入检查收敛")
    parser.add_argument("--mode", choices=("pvp", "team", "royale"), default="royale")
    parser.add_argument("--fps", type=int, default=60, help="客户端渲染帧率上限")
    parser.add_argument("--visible", action="store_true", help="显示客户端窗口")
    parser.add_argument("--no-trace", action="store_true")
    parser.add_argument("--prediction-profile", action="store_true", help="记录预测 tick 的阶段耗时")
    parser.add_argument("--frame-trace", action="store_true", help="后台记录全部帧及模拟/收包/CLI 阶段，支持前后文定位")
    parser.add_argument("--frame-trace-packets", action="store_true", help="同时保存按派发顺序排列的原始游戏报文（开启帧记录）")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--stall", action="store_true", help="对战中双向积压 750 ms 后突发释放，再双向断流 250 ms")
    parser.add_argument("--server-stall-ms", type=int, default=0, help="服务端主线程暂停指定毫秒数后恢复")
    parser.add_argument("--rejoin-delay-seconds", type=float, default=0, help="GNS 重连成功后等待指定秒数再处理 REJOIN")
    parser.add_argument("--none", action="store_true")
    parser.add_argument("--network-seconds", type=float, default=0, help="预热完成后的网络专用墙钟计量窗口")
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("--server", type=Path, help="使用导出的正式服务端")
    parser.add_argument("--tunnel", choices=("direct", "relay"), help="通过官方 EasyTier 运行同一场真实对局")
    parser.add_argument("--easytier-dir", type=Path, default=ROOT/"easytier")
    parser.add_argument("--relays", nargs="+", help="公网 UDP 中继候选，客户端轮换连接顺序")
    parser.add_argument("--pin-client-relays", action="store_true", help="客户端轮换固定接入单个中继，服务端连接全部候选")
    parser.add_argument("--local-relay", action="store_true", help="使用测试进程内启动的本机中继")
    parser.add_argument("--matrix", action="store_true", help="依次运行分档波动网络矩阵")
    parser.add_argument("--counts", nargs="+", type=int, choices=(2,6,8), default=[2,6,8])
    parser.add_argument("--profiles", nargs="+", choices=tuple(PROFILES), default=list(PROFILES))
    parser.add_argument("--seeds", nargs="+", type=int, default=[1000])
    parser.add_argument("--bandwidths", nargs="+", type=float, default=[0])
    args = parser.parse_args()
    if args.timeout is None: args.timeout = 130 if args.matrix else 90
    if args.local_relay and args.tunnel != "relay": parser.error("--local-relay 使用 --tunnel relay")
    if args.pin_client_relays and (args.tunnel != "relay" or args.local_relay):
        parser.error("--pin-client-relays 使用公网 --tunnel relay")
    if args.tunnel and (args.server or args.matrix or args.rtt or args.profile or args.loss or args.bandwidth_kbps or args.stall):
        parser.error("隧道对局单独运行；网络注入矩阵使用本机 UDP 链路")
    args.godot = args.godot.replace("_console.exe", ".exe")  # 直接管理引擎进程，避免退出控制台包装器后留下子进程。
    if args.server and args.count != 2:
        parser.error("导出验证使用 2 人")
    if args.server and (args.stall or args.server_stall_ms):
        parser.error("断流夹具使用编辑器服务端")
    if args.server and args.rejoin_delay_seconds:
        parser.error("延迟重连夹具使用编辑器服务端")
    if args.mode == "pvp" and args.count != 2 or args.mode == "team" and args.count != 6:
        parser.error("pvp 使用 2 人，team 使用 6 人")
    if args.network_seconds and args.mode != "royale":
        parser.error("网络计量使用定时结束的大乱斗")
    return args


def run_match(args):
    mode = args.mode
    duration = max(args.battle_seconds, 9 + args.settle_seconds + args.network_seconds + 6) if args.network_seconds else args.battle_seconds
    port = free_port()
    processes, streams, links = {}, [], []
    tag = f"{mode}_{args.count}_{args.fps}_{args.rtt}_{args.loss}_{'none' if args.none else 'zstd'}"
    if args.server: tag += "_exported"
    if args.stall: tag += "_stall"
    if args.profile: tag += f"_{args.profile}_{args.seed}_{args.bandwidth_kbps}kbps"
    if args.tunnel: tag += "_" + args.tunnel
    folder = (args.output or LOGS / tag).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    started_at = time.monotonic()
    tunnel_code = f"{secrets.randbelow(100000000):08d}"
    core = args.easytier_dir.resolve() / ("easytier-core.exe" if os.name == "nt" else "easytier-core")
    cli = args.easytier_dir.resolve() / ("easytier-cli.exe" if os.name == "nt" else "easytier-cli")
    relays = []
    if args.tunnel == "relay" and not args.local_relay:
        relays = args.relays or (ROOT/"easytier/relay.txt").read_text(encoding="utf-8").splitlines()[:3]
    def tunnel_args(name, neighbors):
        rpc = free_port(socket.SOCK_STREAM)
        host = name == "server"
        index = 0 if host else int(name.removeprefix("client"))+1
        config = folder / (name + ".toml")
        lines = [f'hostname = "cyr-host-{port}"' if host else f'hostname = "cyr-guest-test-{index}"',
                 f'ipv4 = "10.126.126.{index+1}"', 'listeners = ["udp://0.0.0.0:0"]', 'stun_servers = []']
        for uri in neighbors:
            assert uri.startswith("udp://"), uri
            lines += ['[[peer]]', f'uri = {json.dumps(uri)}']
        lines += ['[network_identity]', f'network_name = "cyr-{tunnel_code}"', f'network_secret = "{tunnel_code}"',
                  '[flags]', 'no_tun = true', 'bind_device = false', 'default_protocol = "udp"',
                  'data_compress_algo = "None"', 'enable_ipv6 = false', 'private_mode = true', 'latency_first = true',
                  'disable_tcp_hole_punching = true', 'disable_udp_hole_punching = true',
                  'disable_p2p = ' + str(args.tunnel == "relay").lower()]
        config.write_text("\n".join(lines)+"\n", encoding="utf-8")
        return ["--tunnel-config",str(config),"--tunnel-rpc",str(rpc),"--tunnel-code",tunnel_code,
                "--tunnel-core",str(core),"--tunnel-cli",str(cli)]
    drains = []
    def drain_console(process, stream):
        # Godot's main thread writes to a pipe; disk flushes happen in this reader.
        # Direct file redirection on Windows can turn console output into game stalls.
        def drain():
            with process.stdout:
                while data := process.stdout.read1(65536):
                    stream.write(data)
                    stream.flush()
        thread = threading.Thread(target=drain, daemon=True)
        drains.append(thread)
        thread.start()

    def launch(name, scene, extra):
        env = os.environ.copy()
        if args.tunnel:
            env.pop("RUST_LOG", None)
            for key in list(env):
                if key.startswith("ET_"): env.pop(key)
        for key, leaf in (("APPDATA","roaming"),("LOCALAPPDATA","local")):
            location = folder / name / leaf
            location.mkdir(parents=True, exist_ok=True)
            env[key] = str(location)
        if sys.platform == "darwin":
            profile = (folder / name / "profile").resolve()
            profile.mkdir(parents=True, exist_ok=True)
            env["HOME"] = str(profile)
        stream = (folder / (name + ".log")).open("wb")
        streams.append(stream)
        view = [] if args.visible and name != "server" else ["--headless"]
        cmd = [args.godot, *view, "--path", str(ROOT), "--disable-crash-handler",
               "--max-fps", str(60 if name == "server" else args.fps), scene, "--", *extra]
        if args.server and name == "server":
            cmd = [str(args.server.resolve()), "--headless", "--", "--server", *extra]
        cmd += ["--game-log-dir", str((folder / name / "diagnostics").resolve())]
        if args.frame_trace or args.frame_trace_packets: cmd.append("--frame-trace")
        if args.frame_trace_packets: cmd.append("--frame-trace-packets")
        if name == "server" and not args.server: cmd.append("--server")
        if args.none: cmd.append("--none")
        proc = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                creationflags=0x08000000 if os.name == "nt" else 0)
        processes[name] = proc
        drain_console(proc, stream)
        return proc
    try:
        if args.local_relay:
            relay_port = free_port()
            stream = (folder/"relay.log").open("w",encoding="utf-8")
            streams.append(stream)
            processes["relay"] = subprocess.Popen([str(core),"--no-tun","--bind-device","false","-i","10.125.126.254",
                "--network-name","cyr-test-relay","--network-secret","fixture","--rpc-portal",f"127.0.0.1:{free_port(socket.SOCK_STREAM)}",
                "-l",f"udp://0.0.0.0:{relay_port}","--default-protocol","udp","--disable-ipv6",
                "--relay-network-whitelist","*","--compression","none","--stun-servers"],cwd=ROOT,
                stdout=stream,stderr=subprocess.STDOUT,creationflags=0x08000000 if os.name=="nt" else 0)
            relays = [f"udp://127.0.0.1:{relay_port}"]
        host_extra = tunnel_args("server",relays) if args.tunnel else []
        launch("server", "res://tests/network/match_server.tscn", ["--port",str(port),
               *(["--no-trace"] if args.no_trace else []),
               *(["--network-seconds", str(args.network_seconds), "--settle-seconds", str(args.settle_seconds)] if args.network_seconds else []),
               *(["--server-stall-ms", str(args.server_stall_ms)] if args.server_stall_ms else []),
               *(["--rejoin-delay-seconds", str(args.rejoin_delay_seconds)] if args.rejoin_delay_seconds else []), *host_extra])
        if args.tunnel == "direct":
            deadline = time.monotonic()+20
            while time.monotonic() < deadline:
                result = subprocess.run([str(cli),"--rpc-portal",f"127.0.0.1:{host_extra[3]}","-o","json","node"],
                    capture_output=True,text=True,encoding="utf-8",timeout=5,creationflags=0x08000000 if os.name=="nt" else 0)
                if result.returncode == 0:
                    node = json.loads(result.stdout)
                    relays = [next(url for url in node["listeners"] if url.startswith("udp://0.0.0.0:")).replace("0.0.0.0","127.0.0.1")]
                    break
                time.sleep(.2)
            assert relays, "EasyTier direct listener is not ready"
        else:
            time.sleep(1)
        clients = []
        for index in range(args.count):
            client_port = port
            if not args.tunnel:
                link = LagLink(port, rtt=args.rtt, jitter=args.jitter, loss=args.loss, seed=args.seed+index,
                               profile=args.profile, bandwidth_kbps=args.bandwidth_kbps, queue_ms=args.queue_ms,
                               warmup=bool(args.network_seconds))
                links.append(link)
                client_port = link.port
            extra = ["--port",str(client_port), "--index",str(index), "--count",str(args.count), "--mode",mode, "--battle-seconds",str(duration)]
            if args.prediction_profile: extra.append("--prediction-profile")
            if args.tunnel:
                offset = index % len(relays)
                neighbors = [relays[offset]] if args.pin_client_relays else relays[offset:] + relays[:offset]
                extra += tunnel_args(f"client{index}", neighbors)
            if args.drop and index == 1: extra.append("--drop")
            clients.append(launch(f"client{index}", "res://tests/network/match_client.tscn", extra))
            time.sleep(0.1)
        deadline = time.monotonic() + args.timeout
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
            if any(runtime_error((folder / f"{name}.log").read_text(encoding="utf-8", errors="replace")) for name in ["server", *[f"client{i}" for i in range(args.count)]]):
                stop_reason = "runtime_error"
                break
            if any(client.poll() not in (None, 0) for client in clients):
                stop_reason = "client_exit"
                break
            time.sleep(0.1)
        if stop_reason == "completed" and any(client.poll() is None for client in clients):
            stop_reason = "timeout"
        if all(client.poll() is not None for client in clients):
            for thread in drains: thread.join(timeout=2)
        for stream in streams: stream.flush()
        failures = []
        for index, client in enumerate(clients):
            output = (folder / f"client{index}.log").read_text(encoding="utf-8")
            if client.poll() != 0 or "MATCH CLIENT OK" not in output or runtime_error(output) or "MATCH CLIENT FAIL" in output:
                failures.append(f"client{index}")
        server_output = (folder / "server.log").read_text(encoding="utf-8")
        if ("SERVER READY" if args.server else "MATCH SERVER OK") not in server_output or runtime_error(server_output):
            failures.append("server")
        logging, corrections, tunnel_routes = [], [], []
        for name, process in processes.items():
            if name == "relay": continue
            host = name == "server"
            paths = list((folder / name / "diagnostics").glob(f"*-{process.pid}.log"))
            records = [json.loads(line) for path in paths for line in path.read_text(encoding="utf-8").split("\n")[:-1]]
            events = {record["event"] for record in records}
            expected = {"session_start", "performance", "transport_sample", "world_state", "baseline_send", "player_ready"} if host else {
                "session_start", "session_end", "performance", "transport_sample", "client_state", "baseline_ready"}
            missing = sorted(expected - events)
            if missing: failures.append(f"{name} logging: {missing}")
            samples = [record["data"] for record in records if record["event"] == "client_state"]
            if not host:
                corrections.append({"index": int(name.removeprefix("client")),
                    **{key: sum(sample["counts"].get(key, 0) for sample in samples)
                       for key in ("corrections_8px", "corrections_32px", "corrections_128px")},
                    "max_correction_px": max((sample["correction_max_px"] for sample in samples), default=0),
                    "max_replay_ticks": max((sample["replay_max_ticks"] for sample in samples), default=0)})
            if args.tunnel:
                native = [path for path in (folder/name/"diagnostics/easytier").rglob("*") if path.is_file() and path.stat().st_size]
                if not native: failures.append(f"{name} EasyTier logs missing")
                snapshots = [r["data"]["peers"] for r in records if r["event"] == "tunnel_peers"]
                routes = [peer for peers in snapshots for peer in peers if peer["hostname"] == f"cyr-host-{port}"] if not host else []
                wrong = [peer for peers in snapshots for peer in peers if peer["cost"] == "p2p" and peer["tunnel_proto"] not in ("udp", "udp6")]
                wrong += [peer for peer in routes if not (peer["cost"].startswith("relay(") if args.tunnel == "relay" else peer["cost"] == "p2p")]
                if wrong or (not host and not routes): failures.append(f"{name} tunnel route")
                tunnel_routes.append({"name":name,"host_samples":routes,"bad_routes":wrong,"native_logs":[str(p) for p in native]})
            logging.append({"name": name, "files": [str(path) for path in paths], "records": len(records), "missing": missing})
        if args.stall and (not disturbed or any(link.stalled_packets == 0 or link.blackout_packets == 0 for link in links)):
            failures.append("stall fixture")
        report = {"mode": mode, "fps": args.fps, "count":args.count, "rtt":args.rtt, "jitter":args.jitter, "loss":args.loss,
                  "server_stall_ms": args.server_stall_ms,
                  "rejoin_delay_seconds": args.rejoin_delay_seconds,
                  "drop":args.drop, "compression":"none" if args.none else "zstd", "failures":failures,
                  "stop_reason":stop_reason}
        report.update(profile=args.profile, seed=args.seed, bandwidth_kbps=args.bandwidth_kbps,
                      transport="gns",
                      queue_ms=args.queue_ms, elapsed_seconds=time.monotonic()-started_at,
                      links=[link.report() for link in links])
        report["logging"] = logging
        if any(link.error for link in links):
            failures.append("link emulator")
        report["corrections"] = corrections
        report["gameplay"] = [json.loads(line.removeprefix("GAMEPLAY METRICS "))
                              for line in server_output.splitlines() if line.startswith("GAMEPLAY METRICS ")]
        report["clients"] = [json.loads(output.rsplit("NETWORK METRICS ", 1)[1].splitlines()[0])
                             for output in ((folder / f"client{i}.log").read_text(encoding="utf-8") for i in range(args.count))
                             if "NETWORK METRICS " in output]
        report["exits"] = {name: process.poll() for name, process in processes.items()}
        if args.tunnel: report["tunnel"] = {"mode":args.tunnel,"relays":relays,
                                           "pin_client_relays":args.pin_client_relays,"routes":tunnel_routes}
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
        return report
    finally:
        for proc in processes.values():
            if proc.poll() is None:
                proc.terminate()
        for proc in processes.values():
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        for thread in drains: thread.join(timeout=2)
        for stream in streams: stream.close()
        for link in links: link.close()

def run_matrix(args):
    output = (args.output or LOGS/"tiers").resolve()
    output.mkdir(parents=True,exist_ok=True)
    metadata = {"profiles":PROFILES,"transport":"gns","rtt":"injected_propagation_round_trip",
                "network_seconds":args.network_seconds or 12,"settle_seconds":args.settle_seconds,
                "frame_limit_ms":50,"game_source":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
                "workload":"royale; destructible platforms, real damage and respawns, fixed inputs",
                "script_sha256":{name:hashlib.sha256((ROOT/"tests/network"/name).read_bytes()).hexdigest()
                                 for name in ("match_client.gd","match_server.gd","match_input.gd","network_link.py","run_matches.py","arena.cyrm")}}
    rows = []
    for count,profile,seed,bandwidth in itertools.product(args.counts,args.profiles,args.seeds,args.bandwidths):
        case_args = copy.copy(args)
        case_args.count, case_args.profile, case_args.seed, case_args.bandwidth_kbps = count,profile,seed,bandwidth
        case_args.network_seconds = args.network_seconds or 12
        case_args.no_trace = True
        case_args.output = output/f"{count}_{profile}_{seed}_{bandwidth:g}kbps"
        result = run_match(case_args)
        row = summarize(result)
        row["result"] = str(case_args.output/"result.json")
        rows.append(row)
        (output/"summary.json").write_text(json.dumps({"metadata":metadata,"runs":rows},indent=2),encoding="utf-8")
        print(f"MATRIX {len(rows)} {case_args.output.name} failures={row['failures']}",flush=True)
    return any(row["failures"] for row in rows)


if __name__ == "__main__":
    args = arguments()
    raise SystemExit(run_matrix(args) if args.matrix else bool(run_match(args)["failures"]))

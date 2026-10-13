"""Exercise the supplied official EasyTier using production Tunnel and ENet, with direct and forced relay routes."""
import argparse, json, os, socket, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "easytier/easytier-core.exe"
CLI = ROOT / "easytier/easytier-cli.exe"
def port(kind=socket.SOCK_DGRAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1",0))
        return sock.getsockname()[1]
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    args.godot = args.godot.replace("_console.exe", ".exe")  # 直接管理引擎进程，避免退出控制台包装器后留下子进程。
    relay_file = ROOT / "easytier/relay.txt"
    original = relay_file.read_bytes() if relay_file.exists() else None
    for mode in ("direct","relay"):
        folder = ROOT / ".test_logs/network" / ("easytier_" + mode)
        folder.mkdir(parents=True, exist_ok=True)
        processes, streams = [], []
        def launch(name, command, env):
            log = (folder / (name + ".log")).open("w", encoding="utf-8")
            streams.append(log)
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
            processes.append(proc)
            return proc
        try:
            relay_port, game_port = port(), port()
            relay_file.write_text(f"udp://127.0.0.1:{relay_port}\n", encoding="utf-8")
            relay = launch("relay", [str(CORE), "--no-tun", "--bind-device", "false", "-i", "10.125.126.254",
                "--network-name", "cyr-test-relay", "--network-secret", "fixture",
                "--rpc-portal", f"127.0.0.1:{port(socket.SOCK_STREAM)}",
                "-l", f"udp://0.0.0.0:{relay_port}", "--default-protocol", "udp", "--disable-ipv6",
                "--relay-network-whitelist", "*", "--compression", "none", "--stun-servers"], os.environ.copy())
            time.sleep(1)
            def game(name, host=False):
                env = os.environ.copy()
                for key in list(env):
                    if key.startswith("ET_"): env.pop(key)
                for key, leaf in (("APPDATA","roaming"),("LOCALAPPDATA","local")):
                    loc = folder / name / leaf
                    loc.mkdir(parents=True, exist_ok=True)
                    env[key] = str(loc)
                output = folder / f"{name}.json"
                output.unlink(missing_ok=True)
                command = [args.godot, "--headless", "--path", str(ROOT),
                    "res://tests/network/tunnel_peer.tscn", "--", "--port", str(game_port), "--output", str(output)]
                if host: command.append("--host")
                if mode == "relay":
                    rpc = port(socket.SOCK_STREAM)
                    config = folder / (name + ".toml")
                    text = [
                        'hostname = "' + ("cyr-host-" + str(game_port) if host else "cyr-guest-test") + '"',
                        'listeners = ["udp://0.0.0.0:0"]',
                        'ipv4 = "10.126.126.1"' if host else 'dhcp = true',
                        'stun_servers = []',
                        '[[peer]]', f'uri = "udp://127.0.0.1:{relay_port}"',
                        '[network_identity]', 'network_name = "cyr-00001234"', 'network_secret = "00001234"',
                        '[flags]', 'no_tun = true', 'bind_device = false', 'default_protocol = "udp"',
                        'data_compress_algo = "None"', 'enable_ipv6 = false', 'disable_p2p = true',
                        'disable_udp_hole_punching = true', 'disable_tcp_hole_punching = true',
                    ]
                    config.write_text("\n".join(text)+"\n",encoding="utf-8")
                    command += ["--rpc",str(rpc),"--core-config",str(config)]

                return launch(name,command,env)
            game("host", True)
            deadline = time.monotonic() + 30
            while "TUNNEL HOST READY" not in (folder / "host.log").read_text(encoding="utf-8") and time.monotonic() < deadline:
                if "SCRIPT ERROR" in (folder / "host.log").read_text(encoding="utf-8"): break
                time.sleep(.1)
            assert (folder / "host.json").exists() and "TUNNEL HOST READY" in (folder / "host.log").read_text(encoding="utf-8"), (folder / "host.log").read_text(encoding="utf-8")
            if mode == "direct":
                rpc = json.loads((folder / "host.json").read_text(encoding="utf-8"))["rpc"]
                node = json.loads(subprocess.check_output([str(CLI), "--rpc-portal", f"127.0.0.1:{rpc}",
                    "-o", "json", "node"], text=True, encoding="utf-8"))
                listener = next(url for url in node["listeners"] if url.startswith("udp://0.0.0.0:"))
                # 让客机直接连接房主的实际 UDP 监听口；不依赖本机 NAT 打洞是否被调度。
                relay_file.write_text(listener.replace("0.0.0.0", "127.0.0.1") + "\n", encoding="utf-8")
            guest = game("guest")
            deadline = time.monotonic() + 100
            while guest.poll() is None and time.monotonic() < deadline:
                if "SCRIPT ERROR" in (folder / "guest.log").read_text(encoding="utf-8"): break
                time.sleep(.1)
            log = (folder / "guest.log").read_text(encoding="utf-8")
            assert guest.poll() == 0 and "TUNNEL PEER OK" in log and "SCRIPT ERROR" not in log, log
            peers = json.loads((folder / "guest.json.peers.json").read_text(encoding="utf-8"))
            host_peer = next(peer for peer in peers if peer["hostname"].startswith("cyr-host-"))
            assert (host_peer["cost"] == "p2p" and host_peer["tunnel_proto"] == "udp") if mode == "direct" else host_peer["cost"].startswith("relay("), host_peer
            (folder / "result.json").write_text(json.dumps({"mode": mode, "route": host_peer,
                "input": True, "state": True, "reliable_bytes": 256 * 1024, "reconnect": True,
                "room_code": "00001234"}, indent=2), encoding="utf-8")
            print(f"EASYTIER {mode.upper()} OK",flush=True)
        finally:
            for proc in processes:
                if proc.poll() is None: proc.terminate()
            for proc in processes: proc.wait(timeout=10)
            for stream in streams: stream.close()
            if original is None:
                relay_file.unlink(missing_ok=True)
            else: relay_file.write_bytes(original)
if __name__ == "__main__":
    main()

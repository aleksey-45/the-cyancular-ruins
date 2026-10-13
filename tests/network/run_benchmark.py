"""Replay a captured real match through SceneMultiplayer/ENet, count wire bytes and Windows process CPU."""
import argparse, ctypes, hashlib, json, os, shutil, subprocess, time
from ctypes import wintypes
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".test_logs/network"
def cpu_seconds(pid):
    times = [wintypes.FILETIME() for _ in range(4)]
    kernel = ctypes.windll.kernel32
    kernel.OpenProcess.restype = wintypes.HANDLE
    handle = kernel.OpenProcess(0x1000, False, pid)
    assert handle and kernel.GetProcessTimes(wintypes.HANDLE(handle), *[ctypes.byref(v) for v in times])
    kernel.CloseHandle(wintypes.HANDLE(handle))
    return sum((v.dwHighDateTime << 32) | v.dwLowDateTime for v in times[2:]) / 10_000_000
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--trace", type=Path, help="冻结的上一提交对战记录，供两种协议重放同一负载")
    args = parser.parse_args()
    args.godot = args.godot.replace("_console.exe", ".exe")  # 直接管理引擎进程，避免退出控制台包装器后留下子进程。
    capture = OUT / "benchmark" / f"trace_{args.count}.bin"
    capture.parent.mkdir(parents=True, exist_ok=True)
    source = args.trace or OUT / f"trace_{args.count}.bin"
    shutil.copy2(source, capture)
    digest = hashlib.sha256(capture.read_bytes()).hexdigest()
    reports = []
    for layout, mode in ((layout, mode) for layout in ("variant_full", "binary_delta") for mode in ("none", "zstd")):
        output = OUT / f"benchmark_{args.count}_{layout}_{mode}.json"
        env = os.environ.copy()
        for key, leaf in (("APPDATA","roaming"),("LOCALAPPDATA","local")):
            loc = OUT / "benchmark" / leaf
            loc.mkdir(parents=True, exist_ok=True)
            env[key] = str(loc)
        command = [args.godot, "--headless", "--path", str(ROOT), "res://tests/network/wire_benchmark.tscn", "--",
                   "--trace", str(capture), "--output", str(output)]
        if mode == "none": command.append("--none")
        if layout == "variant_full": command.append("--legacy")
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", errors="replace", creationflags=0x08000000)
        starts, cpus = {}, {}
        phase_file = Path(str(output) + ".phase")
        phase_file.unlink(missing_ok=True)
        log_path = OUT / f"benchmark_{args.count}_{layout}_{mode}.log"
        import threading
        lines = []
        def read_output():
            for line in process.stdout:
                lines.append(line)
                if "SCRIPT ERROR" in line:
                    process.terminate()
        reader = threading.Thread(target=read_output)
        reader.start()
        last = ""
        while process.poll() is None:
            if phase_file.exists():
                phase = phase_file.read_text(encoding="utf-8")
                if phase and phase != last:
                    name, event, real_pid = phase.split(":")
                    benchmark_pid = int(real_pid)
                    current_cpu = cpu_seconds(benchmark_pid)
                    if event == "start": starts[name] = current_cpu
                    elif name in starts: cpus[name] = current_cpu - starts[name]
                    last = phase
            time.sleep(0.002)
        code = process.wait(timeout=30)
        if "battle" not in cpus and "battle" in starts:
            cpus["battle"] = cpu_seconds(benchmark_pid) - starts["battle"]
        reader.join()
        log_path.write_text("".join(lines), encoding="utf-8")
        assert code == 0 and any("WIRE BENCHMARK OK" in line for line in lines), lines[-10:]
        report = json.loads(output.read_text(encoding="utf-8"))
        report["trace_sha256"] = digest
        for phase in ("baseline", "battle"):
            report[phase]["process_cpu_ms"] = cpus[phase] * 1000
            report[phase]["one_core_cpu_percent"] = cpus[phase] * 100000 / report[phase]["elapsed_ms"]
        output.write_text(json.dumps(report, indent=2), encoding="utf-8")
        reports.append(report)
    (OUT / f"benchmark_{args.count}.json").write_text(json.dumps(reports, indent=2), encoding="utf-8")
    print("BENCHMARK OK " + json.dumps(reports), flush=True)
if __name__ == "__main__":
    main()

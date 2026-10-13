#!/usr/bin/env python3
"""运行 Godot 逻辑冒烟与场景探针；成功要求退出 0、成功标记和没有脚本错误。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / ".test_logs"
NETWORK = {"transport_probe", "authority_probe", "local_server_probe", "input_playback_smoke", "playback_lifecycle_probe", "protocol_probe", "movement_probe"}
VISUAL = {"combat_hud_visual_probe", "kh_l3_visual_probe", "kh_l4_visual_probe", "kh_visual_probe",
          "minimap_circle_probe", "squash_stretch_probe", "hue_tint_probe", "match_result_probe"}
sys.stdout.reconfigure(encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT"), required=not os.environ.get("GODOT"))
    parser.add_argument("--scenes", action="store_true")
    parser.add_argument("--kind", choices=("unit", "network", "visual"), default="unit")
    parser.add_argument("--diagnostics", action="store_true")
    parser.add_argument("--only", nargs="*", default=[])
    parser.add_argument("--skip", nargs="*", default=[])
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=150)
    args = parser.parse_args()
    args.godot = args.godot.replace("_console.exe", ".exe")  # 直接管理引擎进程，避免退出控制台包装器后留下子进程。
    env = os.environ.copy()
    env["GODOT"] = args.godot
    env["PYTHONUTF8"] = "1"
    for key, folder in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local")):
        location = LOGS / "profile" / folder
        location.mkdir(parents=True, exist_ok=True)
        env[key] = str(location)
    tests = []
    for bucket in ("smoke", "probe", "network"):
        for script in sorted((ROOT / "tests" / bucket).glob("*.gd")):
            if bucket == "network" and script.stem not in NETWORK:
                continue  # 多进程夹具需要参数，由 tests/network/run_*.py 调度。
            if script.stem in args.skip:
                continue
            source = script.read_text(encoding="utf-8")
            kind = "network" if script.stem in NETWORK else "visual" if script.stem in VISUAL else "unit"
            if not args.only and kind != args.kind:
                continue
            if not args.diagnostics and not args.only and kind == "unit" and not (re.search(r'print\(\s*"[^"]*(?:OK|PASS)', source) or "extends ProbeBase" in source):
                continue
            scene = script.with_suffix(".tscn")
            target = scene if args.scenes and scene.exists() else script
            if target == script and not re.search(r"^extends SceneTree", source, re.M):
                continue
            if args.only and script.stem not in args.only:
                continue
            tests.append(target)
    def run(target):
        stem = target.stem
        case_env = env.copy()
        for key, folder in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local")):
            location = LOGS / "profile" / stem / folder
            location.mkdir(parents=True, exist_ok=True)
            case_env[key] = str(location)
        display = ["--rendering-method", "gl_compatibility", "--position", "-10000,-10000"] if stem in VISUAL else ["--headless"]
        cmd = [args.godot, *display, "--path", str(ROOT),
               "--log-file", str(LOGS / (stem + ".engine.log")), "--disable-crash-handler"]
        cmd += ["-s", "res://" + target.relative_to(ROOT).as_posix()] if target.suffix == ".gd" else [
            "res://" + target.relative_to(ROOT).as_posix()]
        output_path = LOGS / (stem + ".output.log")
        with output_path.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(cmd, cwd=ROOT, env=case_env, stdout=stream,
                                       stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=args.timeout)
                output = output_path.read_text(encoding="utf-8", errors="replace")
                ok = code == 0 and bool(re.search(
                    r"(?m)^[A-Za-z][A-Za-z0-9_ :/-]*(?:OK|ALL-OK|PASS)(?=$|[^A-Z0-9_])", output))
                ok &= "SCRIPT ERROR" not in output
                status = {"test": stem, "ok": ok, "exit": code}
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                status = {"test": stem, "ok": False, "timeout": True}
        print(("PASS " if status["ok"] else "FAIL ") + stem, flush=True)
        return status
    with ThreadPoolExecutor(max_workers=1 if args.kind != "unit" else args.jobs) as pool:
        results = list(pool.map(run, tests))
    summary = LOGS / ("regression_" + args.kind + ".json")
    merged = results
    if args.only and summary.exists():
        names = {result["test"] for result in results}
        merged = [result for result in json.loads(summary.read_text(encoding="utf-8"))
                  if result["test"] not in names] + results
    summary.write_text(json.dumps(merged, indent=2), encoding="utf-8")
    passed = sum(result["ok"] for result in results)
    print(f"REGRESSION {passed}/{len(results)} passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()

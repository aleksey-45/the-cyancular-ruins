"""Verify ENet reconciliation and prediction presentation at different render rates."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    output = ROOT / ".test_logs/network"
    output.mkdir(parents=True, exist_ok=True)
    report = []
    for fps in (30, 144, 240):
        env = os.environ.copy()
        for key, leaf in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local")):
            location = output / f"movement_{fps}" / leaf
            location.mkdir(parents=True, exist_ok=True)
            env[key] = str(location)
        log = output / f"movement_{fps}.log"
        with log.open("w", encoding="utf-8") as stream:
            result = subprocess.run([args.godot.replace("_console.exe", ".exe"), "--headless", "--path", str(ROOT),
                                     "res://tests/network/movement_probe.tscn", "--", "--fps", str(fps)],
                                    cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                    creationflags=0x08000000, timeout=20)
        text = log.read_text(encoding="utf-8")
        assert result.returncode == 0 and "MOVEMENT PROBE OK" in text and "SCRIPT ERROR" not in text, text
        corrections, error = re.search(r"MOVEMENT PROBE OK .*corrections=(\d+) max=([\d.]+)", text).groups()
        samples, stationary, average = re.search(r"DISPLAY METRICS samples=(\d+) stationary=(\d+) average_fps=([\d.]+)", text).groups()
        report.append({"fps_limit": fps, "corrections": int(corrections), "max_correction_px": float(error),
                       "render_samples": int(samples), "stationary_frames": int(stationary), "average_fps": float(average), "exit": result.returncode})
        print(f"MOVEMENT {fps} FPS OK", flush=True)
    (output / "movement_rates.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()

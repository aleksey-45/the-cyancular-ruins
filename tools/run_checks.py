"""以无头模式启动 Godot 并运行指定的测试组。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from godot_log import FATAL

ROOT = Path(__file__).resolve().parents[1]
CHECK_TIMEOUT_SECONDS = 120
sys.stdout.reconfigure(encoding='utf-8', errors='replace')


def run(command, marker=None):
    try:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=CHECK_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode("utf-8", errors="replace"), file=sys.stderr)
        print(f"Godot timed out ({CHECK_TIMEOUT_SECONDS} seconds)", file=sys.stderr)
        return False
    log = result.stdout.decode("utf-8", errors="replace")
    print(log, end="")
    return result.returncode == 0 and not FATAL.search(log) and (marker is None or marker in log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.environ.get('GODOT') or os.environ.get('GODOT_EDITOR') or shutil.which('godot'))
    parser.add_argument('--groups', default='net,transport,terrain,simulation,prediction,monitor,editor,lan')
    args = parser.parse_args()
    if not args.godot:
        parser.error('set GODOT or pass --godot; build native extensions and import the project first')
    engine = [args.godot, "--headless", "--path", str(ROOT)]
    scripts = [ROOT / "tests/weapon_load.gd"]
    tools = ROOT.parent / "test-tools"
    if tools.is_dir():
        scripts.extend([tools / "match_driver.gd", tools / "replay.gd"])
    for script in scripts:
        if not run([*engine, "--check-only", "--script", str(script)]):
            return 1
    return 0 if run([*engine, "res://tests/run.tscn", "--", "--no-perf", "--groups", args.groups],
                    "CHECKS COMPLETE failures=0") else 1


if __name__ == '__main__':
    sys.exit(main())

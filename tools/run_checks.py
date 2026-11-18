"""启动一个无界面的 Godot 实例，在其中运行指定的测试组。"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECK_TIMEOUT_SECONDS = 120
sys.stdout.reconfigure(encoding='utf-8', errors='replace')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.environ.get('GODOT') or os.environ.get('GODOT_EDITOR') or shutil.which('godot'))
    parser.add_argument('--groups', default='net,transport,terrain,simulation,prediction,monitor')
    args = parser.parse_args()
    if not args.godot:
        parser.error('set GODOT or pass --godot; build native extensions and import the project first')
    command = [args.godot, '--headless', '--path', str(ROOT), 'res://tests/run.tscn',
               '--', '--no-perf', '--groups', args.groups]
    with tempfile.TemporaryFile() as output:
        timed_out = False
        try:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, cwd=ROOT,
                                    timeout=CHECK_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            print(f'Behavior checks timed out ({CHECK_TIMEOUT_SECONDS} seconds); not retried.', file=sys.stderr)
            timed_out = True
        output.seek(0)
        log = output.read().decode('utf-8', errors='replace')
    print(log, end='')
    errors = re.search(r'(?:SCRIPT ERROR|Parse Error|Compile Error|ERROR:)', log)
    return 0 if not timed_out and result.returncode == 0 and not errors and 'CHECKS COMPLETE failures=0' in log else 1


if __name__ == '__main__':
    sys.exit(main())

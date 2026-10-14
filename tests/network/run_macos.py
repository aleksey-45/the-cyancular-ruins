"""Verify the packaged macOS app and real child process ownership on the current CPU."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / '.test_logs/macos'
sys.path.insert(0, str(ROOT / 'tools'))
from build_release import check_weapon_registry


def run(*command):
    subprocess.run([str(item) for item in command], cwd=ROOT, check=True)


def smoke(executable, arguments, marker):
    result = subprocess.run([str(executable), '--headless', '--quit-after', '120', *arguments],
                            cwd=executable.parent, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    (LOGS / ('server.log' if '--server' in arguments else 'client.log')).write_text(output, encoding='utf-8')
    assert result.returncode == 0 and marker in output, output
    assert not any(error in output for error in ('SCRIPT ERROR', 'Parse Error', 'Failed to load')), output
    return output


def alive(pid):
    result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
    return result.returncode == 0 and not result.stdout.strip().startswith('Z')


def startup_profile(godot):
    for name, flags in (('timing', []), ('profile', ['--debug', '--ignore-error-breaks', '--profiling'])):
        result = subprocess.run([godot, '--headless', '--path', str(ROOT), *flags,
            'res://tests/network/startup_probe.tscn'], cwd=ROOT, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        (LOGS / ('startup_' + name + '.log')).write_text(output, encoding='utf-8')
        assert result.returncode == 0 and 'STARTUP PROFILE OK' in output and 'SCRIPT ERROR' not in output, output[-4000:]
        lines = output.splitlines()
        print('STARTUP MEASUREMENT ' + name, flush=True)
        for index, line in enumerate(lines):
            if line.startswith('STARTUP PROFILE '):
                print(line, flush=True)
            if line.startswith('FRAME: total: ') and float(line.split()[2]) > 0.1:
                print('\n'.join(lines[index:index + 43]), flush=True)


def lifecycle(godot):
    core = ROOT / 'easytier/easytier-core'
    control = subprocess.Popen([str(core), '--no-tun', '--network-name', 'cyr-unrelated-test',
                                '--network-secret', 'unrelated', '--listeners', 'udp://127.0.0.1:0',
                                '--rpc-portal', '127.0.0.1:0'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for mode in ('normal', 'window', 'leave', 'transition', 'forced', 'startup'):
            info = LOGS / f'{mode}.json'
            for file in LOGS.glob(mode + '.json*'): file.unlink()
            pids = {}
            log = LOGS / f'{mode}.log'
            with log.open('w', encoding='utf-8') as stream:
                client = subprocess.Popen([godot, '--headless', '--path', str(ROOT),
                    'res://tests/network/process_owner_probe.tscn', '--', '--mode', mode, '--output', str(info)],
                    cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 30
                    while not info.exists() and time.monotonic() < deadline:
                        assert client.poll() is None, log.read_text(encoding='utf-8')
                        time.sleep(0.02)
                    pids = {key: int(value) for key, value in json.loads(info.read_text(encoding='utf-8')).items()}
                    assert pids.pop('client') == client.pid
                    assert all(alive(pid) for pid in pids.values()), pids
                    if mode in ('forced', 'startup'): client.kill()
                    code = client.wait(timeout=25)
                    output = log.read_text(encoding='utf-8')
                    assert 'SCRIPT ERROR' not in output and 'PROCESS OWNER READY' in output, output
                    if mode not in ('forced', 'startup'):
                        assert code == 0, output
                        marker = {'normal': 'PROCESS OWNER QUIT', 'window': 'PROCESS OWNER READY',
                                  'leave': 'PROCESS SESSION REOPEN OK', 'transition': 'PROCESS SCENE TRANSITION OK'}[mode]
                        assert marker in output, output
                    deadline = time.monotonic() + 5
                    while any(alive(pid) for pid in pids.values()) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    assert not any(alive(pid) for pid in pids.values()), f'{mode}: leftover {pids}'
                    assert control.poll() is None, 'unrelated EasyTier was terminated'
                    print(f'MACOS PROCESS LIFECYCLE {mode} OK', flush=True)
                finally:
                    if client.poll() is None: client.kill(); client.wait(timeout=5)
                    for pid in pids.values():
                        if alive(pid): os.kill(pid, 9)
    finally:
        control.terminate()
        control.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--archive', type=Path, required=True)
    args = parser.parse_args()
    LOGS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='package-', dir=LOGS) as temporary:
        run('ditto', '-x', '-k', args.archive.resolve(), temporary)
        app = next(Path(temporary).glob('The-Cyancular-Ruins-*/*.app'))
        manifest = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        executable = app / 'Contents/MacOS' / manifest['CFBundleExecutable']
        extension = next(app.rglob('process_group.macos.universal.dylib'))
        helpers = app / 'Contents/Helpers'
        assert {binary.name for binary in helpers.iterdir()} == {'easytier-core', 'easytier-cli'}
        for binary in (executable, extension, helpers / 'easytier-core', helpers / 'easytier-cli'):
            run('lipo', binary, '-verify_arch', 'arm64', 'x86_64')
            if binary != extension: assert os.access(binary, os.X_OK), binary
        run('codesign', '--verify', '--deep', '--strict', app)
        check_weapon_registry(smoke(executable, ['--', '--registry-report'], '[registry] weapons='))
        smoke(executable, ['--', '--server', '--port', '0'], 'SERVER READY')
        (ROOT / 'native/process_group/bin').mkdir(parents=True, exist_ok=True)
        shutil.copy2(extension, ROOT / 'native/process_group/bin' / extension.name)
        (ROOT / 'easytier').mkdir(exist_ok=True)
        for binary in helpers.iterdir(): shutil.copy2(binary, ROOT / 'easytier' / binary.name)
        run(args.godot, '--headless', '--editor', '--path', ROOT, '--import')
        startup_profile(args.godot)
        lifecycle(args.godot)
        run(sys.executable, ROOT / 'tools/run_regression.py', '--godot', args.godot, '--scenes', '--kind', 'network')
        print((ROOT / '.test_logs/transport_probe.output.log').read_text(encoding='utf-8'), flush=True)
        run(sys.executable, ROOT / 'tests/network/run_matches.py', '--godot', args.godot,
            '--count', '2', '--server', executable, '--drop')
        run(sys.executable, ROOT / 'tests/network/run_easytier.py', '--godot', args.godot)
        run('codesign', '--verify', '--deep', '--strict', app)
    print('MACOS PACKAGE AND LIFECYCLE ALL OK', flush=True)


if __name__ == '__main__':
    main()

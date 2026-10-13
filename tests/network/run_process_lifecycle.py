"""Check real Windows child processes across normal exit, hard kill and scene changes."""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / '.test_logs/process_lifecycle'
kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    args = parser.parse_args()
    output = LOGS
    output.mkdir(parents=True, exist_ok=True)
    # An independent EasyTier with the same executable name must survive every client exit.
    control = subprocess.Popen([str(ROOT / 'easytier/easytier-core.exe'), '--no-tun',
                                '--network-name', 'cyr-unrelated-test', '--network-secret', 'unrelated',
                                '--listeners', 'udp://127.0.0.1:0', '--rpc-portal', '127.0.0.1:0'],
                               cwd=ROOT / 'easytier', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               creationflags=0x08000000)
    results = []
    try:
        for mode in ('normal', 'window', 'leave', 'transition', 'forced', 'startup'):
            info = output / f'{mode}.json'
            for file in output.glob(mode + '.json*'): file.unlink()
            env = os.environ.copy()
            for key, leaf in (('APPDATA', 'roaming'), ('LOCALAPPDATA', 'local')):
                location = output / mode / leaf
                location.mkdir(parents=True, exist_ok=True)
                env[key] = str(location)
            handles = {}
            log = output / f'{mode}.log'
            with log.open('w', encoding='utf-8') as stream:
                command = [args.godot.replace('_console.exe', '.exe'), '--headless', '--path', str(ROOT),
                           'res://tests/network/process_owner_probe.tscn', '--', '--mode', mode, '--output', str(info)]
                client = subprocess.Popen(command,
                                          cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                          creationflags=0x08000000)
                try:
                    deadline = time.monotonic() + 20
                    while not info.exists() and time.monotonic() < deadline:
                        assert client.poll() is None, log.read_text(encoding='utf-8')
                        time.sleep(0.02)
                    pids = json.loads(info.read_text(encoding='utf-8'))
                    assert pids['client'] == client.pid
                    for name, pid in pids.items():
                        if name == 'client': continue
                        handle = kernel.OpenProcess(0x101001, False, int(pid))
                        state = kernel.WaitForSingleObject(handle, 0) if handle else -1
                        if state != 258:
                            code = wintypes.DWORD()
                            if handle: kernel.GetExitCodeProcess(handle, ctypes.byref(code)); kernel.CloseHandle(handle)
                            raise AssertionError(f'{name} pid={pid} handle={handle} state={state} code={code.value} error={ctypes.get_last_error()}')
                        handles[name] = handle
                    if mode in ('forced', 'startup'): client.terminate()
                    code = client.wait(timeout=20)
                    text = log.read_text(encoding='utf-8')
                    assert 'SCRIPT ERROR' not in text and 'PROCESS OWNER READY' in text, text
                    if mode not in ('forced', 'startup'):
                        assert code == 0, text
                        marker = {'normal': 'PROCESS OWNER QUIT', 'window': 'PROCESS OWNER READY',
                                  'leave': 'PROCESS SESSION REOPEN OK', 'transition': 'PROCESS SCENE TRANSITION OK'}[mode]
                        assert marker in text, text
                    for name, handle in handles.items():
                        assert kernel.WaitForSingleObject(handle, 3000) == 0, f'{mode}: leftover {name}'
                    assert control.poll() is None, 'unrelated EasyTier was terminated'
                    results.append({'mode': mode, 'exit': code, 'children': sorted(handles),
                                    'all_children_exited': True, 'unrelated_survived': True})
                    print(f'PROCESS LIFECYCLE {mode} OK', flush=True)
                finally:
                    if client.poll() is None: client.terminate(); client.wait(timeout=5)
                    for handle in handles.values():
                        if kernel.WaitForSingleObject(handle, 0) == 258:
                            kernel.TerminateProcess(handle, 1)
                            kernel.WaitForSingleObject(handle, 5000)
                        kernel.CloseHandle(handle)
    finally:
        if control.poll() is None: control.terminate(); control.wait(timeout=5)
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print('PROCESS LIFECYCLE ALL OK', flush=True)


if __name__ == '__main__':
    main()

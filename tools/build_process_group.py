"""Build the Windows x64 or macOS universal process lifecycle extension."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SDK_TAG = 'godot-4.5-stable'
SDK_COMMIT = 'e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('windows', 'macos'),
                        default='macos' if sys.platform == 'darwin' else 'windows')
    parser.add_argument('--mingw', type=Path, default=os.environ.get('MINGW_PREFIX'),
                        help='LLVM MinGW installation directory; otherwise use MSVC')
    args = parser.parse_args()
    sdk = ROOT / '.test_logs/native/godot-cpp'
    if not sdk.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', SDK_TAG,
                        'https://github.com/godotengine/godot-cpp.git', str(sdk)], check=True)
    actual = subprocess.check_output(['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == SDK_COMMIT, actual
    env = os.environ.copy()
    env['GODOT_CPP_DIR'] = sdk.as_posix()
    local_scons = ROOT / '.test_logs/native/python'
    if local_scons.exists(): env['PYTHONPATH'] = str(local_scons)
    arch = 'universal' if args.platform == 'macos' else 'x86_64'
    command = [sys.executable, '-m', 'SCons', '-j', '4', 'platform=' + args.platform, 'target=template_release',
               'arch=' + arch,
               'build_profile=' + (ROOT / 'native/process_group/build_profile.json').as_posix()]
    if args.platform == 'macos':
        command += ['macos_deployment_target=12.0']
    elif args.mingw:
        command += ['use_mingw=yes', 'use_llvm=yes', 'mingw_prefix=' + args.mingw.resolve().as_posix()]
    subprocess.run(command, cwd=ROOT / 'native/process_group', env=env, check=True)
    suffix = 'dylib' if args.platform == 'macos' else 'dll'
    library = ROOT / f'native/process_group/bin/process_group.{args.platform}.{arch}.{suffix}'
    assert library.is_file()
    if args.platform == 'macos':
        subprocess.run(['lipo', str(library), '-verify_arch', 'arm64', 'x86_64'], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(library)], check=True)
    print('PROCESS GROUP BUILD OK', flush=True)


if __name__ == '__main__':
    main()

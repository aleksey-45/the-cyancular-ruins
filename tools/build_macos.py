"""Build and package a universal macOS app with its EasyTier helpers."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from archive_build import build_stamp, package_name, read_project_version, release_version
from build_release import BUILD_INFO, stamp_build_info

ROOT = Path(__file__).resolve().parents[1]


def run(*command):
    subprocess.run([str(item) for item in command], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.environ.get('GODOT_EDITOR', 'godot'))
    parser.add_argument('--stamp', default=build_stamp())
    parser.add_argument('--version', default=read_project_version())
    args = parser.parse_args()
    run(sys.executable, ROOT / 'tools/build_process_group.py', '--platform', 'macos')
    run(sys.executable, ROOT / 'tools/build_gns.py', '--platform', 'macos')
    run(sys.executable, ROOT / 'tools/build_simulation.py', '--platform', 'macos')
    run(sys.executable, ROOT / 'tools/fetch_easytier.py', '--platform', 'macos')
    builds = ROOT / 'builds/macos'
    builds.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cyancular-macos-') as temporary:
        package = Path(temporary) / package_name(args.stamp)
        package.mkdir()
        app = package / 'The Cyancular Ruins.app'
        original = stamp_build_info(release_version(args.version), args.stamp)
        try:
            run(args.godot, '--headless', '--editor', '--path', ROOT, '--import')
            run(args.godot, '--headless', '--path', ROOT, '--export-release', 'macOS', app)
        finally:
            Path(BUILD_INFO).write_text(original, encoding='utf-8', newline='\n')
        helpers = app / 'Contents/Helpers'
        helpers.mkdir(parents=True, exist_ok=True)
        for name in ('easytier-core', 'easytier-cli'):
            target = helpers / name
            shutil.copy2(ROOT / 'easytier' / name, target)
            run('lipo', target, '-verify_arch', 'arm64', 'x86_64')
            run('codesign', '--force', '--sign', '-', '--timestamp=none', target)
        for name in ('process_group', 'gns', 'simulation'):
            extension = next(app.rglob(name + '.macos.universal.dylib'))
            run('lipo', extension, '-verify_arch', 'arm64', 'x86_64')
            run('codesign', '--force', '--sign', '-', '--timestamp=none', extension)
        run('codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime',
            '--entitlements', ROOT / 'tools/macos_entitlements.plist', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.txt', package)
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', package,
            builds / 'The-Cyancular-Ruins.zip')
    print('MACOS BUILD OK (arm64 + x86_64)', flush=True)


if __name__ == '__main__':
    main()

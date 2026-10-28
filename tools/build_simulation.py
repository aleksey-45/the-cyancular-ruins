"""Build scene-based native simulation for Windows x64 or universal macOS."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import sys

from build_gns import CACHE, ROOT, run, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('windows', 'macos'),
                        default='macos' if sys.platform == 'darwin' else 'windows')
    parser.add_argument('--mingw', type=Path, default=os.environ.get('MINGW_PREFIX'))
    args = parser.parse_args()
    sdk = source('godot-cpp')
    env = os.environ.copy()
    cmake = shutil.which('cmake') or str(CACHE / 'python/cmake/data/bin/cmake.exe')
    ninja = shutil.which('ninja') or str(CACHE / 'ninja_tool/bin/ninja.exe')
    flags = ['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + ninja, '-DCMAKE_BUILD_TYPE=Release',
             '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DPython3_EXECUTABLE=' + sys.executable,
             '-DGODOT_CPP_DIR=' + sdk.as_posix(), '-DSIM_PLATFORM=' + args.platform]
    toolchain = 'apple-clang'
    if args.platform == 'windows':
        mingw = args.mingw
        cached = CACHE / 'llvm-mingw-20261006-ucrt-x86_64'
        if not mingw and not shutil.which('cl') and cached.exists():
            mingw = cached
        toolchain = 'mingw' if mingw else 'msvc'
        if mingw:
            env['PATH'] = str(mingw / 'bin') + os.pathsep + env['PATH']
            flags += ['-DCMAKE_CXX_COMPILER=' + (mingw / 'bin/clang++.exe').as_posix()]
    architectures = ['x86_64']
    if args.platform == 'macos':
        architectures = ['arm64', 'x86_64'] if platform.machine() == 'arm64' else ['x86_64', 'arm64']
    outputs = []
    for arch in architectures:
        build = CACHE / f'simulation-{args.platform}-{arch}-{toolchain}'
        arch_flags = ['-DSIM_ARCH=' + arch]
        if args.platform == 'macos':
            arch_flags += ['-DCMAKE_OSX_ARCHITECTURES=' + arch, '-DCMAKE_SYSTEM_NAME=Darwin',
                           '-DCMAKE_SYSTEM_PROCESSOR=' + arch, '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0']
        run(cmake, '-S', ROOT / 'native/simulation', '-B', build, *flags, *arch_flags, env=env)
        run(cmake, '--build', build, '--parallel', '4', env=env)
        suffix = 'dylib' if args.platform == 'macos' else 'dll'
        outputs.append(ROOT / f'native/simulation/bin/simulation.{args.platform}.{arch}.{suffix}')
    if args.platform == 'macos':
        universal = ROOT / 'native/simulation/bin/simulation.macos.universal.dylib'
        run('lipo', '-create', *outputs, '-output', universal)
        run('lipo', universal, '-verify_arch', 'arm64', 'x86_64')
        run('codesign', '--force', '--sign', '-', '--timestamp=none', universal)
    print('SIMULATION BUILD OK', flush=True)


if __name__ == '__main__':
    main()

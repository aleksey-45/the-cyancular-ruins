"""Build the GNS GDExtension for Windows x64 or macOS arm64 + x86_64."""
import argparse
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.test_logs/native'
SOURCES = {
    'gns': ('ValveSoftware/GameNetworkingSockets', 'v1.6.1', 'd534c19aa760df3fb75fd20db13ba1932b8a5463'),
    'protobuf': ('protocolbuffers/protobuf', 'v21.12', 'f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c'),
    'godot-cpp': ('godotengine/godot-cpp', 'godot-4.5-stable', 'e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77'),
    'openssl': ('openssl/openssl', 'openssl-3.5.9', '45e844fa2a14ec92d146bd8f5778ac130b6625fb'),
}


def run(*command, cwd=ROOT, env=None):
    subprocess.run([str(item) for item in command], cwd=cwd, env=env, check=True)


def source(name):
    repo, tag, commit = SOURCES[name]
    path = CACHE / name
    if not path.exists():
        run('git', 'clone', '--depth', '1', '--branch', tag, 'https://github.com/' + repo + '.git', path)
    actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == commit, (name, actual)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('windows', 'macos'),
                        default='macos' if sys.platform == 'darwin' else 'windows')
    parser.add_argument('--mingw', type=Path, default=os.environ.get('MINGW_PREFIX'))
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    gns, protobuf, sdk = (source(name) for name in ('gns', 'protobuf', 'godot-cpp'))
    env = os.environ.copy()
    cmake = shutil.which('cmake') or str(CACHE / 'python/cmake/data/bin/cmake.exe')
    ninja = shutil.which('ninja') or str(CACHE / 'ninja_tool/bin/ninja.exe')
    flags = ['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + ninja, '-DCMAKE_BUILD_TYPE=Release',
             '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
             '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DPython3_EXECUTABLE=' + sys.executable]
    toolchain = 'apple-clang'
    if args.platform == 'windows':
        mingw = args.mingw
        cached = CACHE / 'llvm-mingw-20261006-ucrt-x86_64'
        if not mingw and not shutil.which('cl') and cached.exists(): mingw = cached
        if mingw:
            env['PATH'] = str(mingw / 'bin') + os.pathsep + env['PATH']
            flags += ['-DCMAKE_C_COMPILER=' + (mingw / 'bin/clang.exe').as_posix(),
                      '-DCMAKE_CXX_COMPILER=' + (mingw / 'bin/clang++.exe').as_posix()]
        toolchain = 'mingw' if mingw else 'msvc'
    architectures = ['x86_64']
    if args.platform == 'macos':
        architectures = ['arm64', 'x86_64'] if platform.machine() == 'arm64' else ['x86_64', 'arm64']
    host_protoc = None
    outputs = []
    for arch in architectures:
        # Keep incompatible compiler ABIs and the old protobuf /MD cache separate.
        triplet = f'{args.platform}-{arch}-{toolchain}'
        prefix = CACHE / ('gns-deps-' + triplet)
        arch_flags = flags + (['-DCMAKE_OSX_ARCHITECTURES=' + arch,
                               '-DCMAKE_SYSTEM_NAME=Darwin', '-DCMAKE_SYSTEM_PROCESSOR=' + arch,
                               '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0'] if args.platform == 'macos' else [])
        pb_build = CACHE / ('protobuf-' + triplet)
        if not (prefix / 'include/google/protobuf/message.h').exists():
            # The deprecated cmake/ wrapper enables MSVC before CMP0091 is NEW,
            # leaving /MD in the default flags despite the requested static CRT.
            run(cmake, '-S', protobuf, '-B', pb_build, *arch_flags,
                '-Dprotobuf_BUILD_TESTS=OFF', '-Dprotobuf_WITH_ZLIB=OFF', '-Dprotobuf_BUILD_SHARED_LIBS=OFF',
                '-Dprotobuf_MSVC_STATIC_RUNTIME=ON', '-Dprotobuf_BUILD_PROTOC_BINARIES=' + ('OFF' if host_protoc else 'ON'),
                '-DCMAKE_INSTALL_PREFIX=' + prefix.as_posix(), env=env)
            run(cmake, '--build', pb_build, '--parallel', '4', env=env)
            run(cmake, '--install', pb_build, env=env)
        if host_protoc is None:
            host_protoc = prefix / ('bin/protoc.exe' if args.platform == 'windows' else 'bin/protoc')
        extra = []
        if args.platform == 'macos':
            ssl = source('openssl')
            ssl_build = CACHE / ('openssl-macos-' + arch)
            if not (prefix / 'lib/libcrypto.a').exists():
                ssl_build.mkdir(parents=True, exist_ok=True)
                ssl_env = env | {'MACOSX_DEPLOYMENT_TARGET': '12.0'}
                target = 'darwin64-arm64-cc' if arch == 'arm64' else 'darwin64-x86_64-cc'
                run('perl', ssl / 'Configure', target, 'no-shared', 'no-tests', 'no-apps',
                    '--prefix=' + str(prefix), '--libdir=lib', cwd=ssl_build, env=ssl_env)
                run('make', '-j4', cwd=ssl_build, env=ssl_env)
                run('make', 'install_sw', cwd=ssl_build, env=ssl_env)
            extra += ['-DOPENSSL_ROOT_DIR=' + prefix.as_posix()]
        build = CACHE / ('gns-extension-' + triplet)
        run(cmake, '-S', ROOT / 'native/gns', '-B', build, *arch_flags, *extra,
            '-DGODOT_CPP_DIR=' + sdk.as_posix(), '-DGNS_DIR=' + gns.as_posix(),
            '-DGNS_PLATFORM=' + args.platform, '-DGNS_ARCH=' + arch,
            '-DCMAKE_PREFIX_PATH=' + prefix.as_posix(),
            '-DProtobuf_PROTOC_EXECUTABLE=' + host_protoc.as_posix(),
            '-DGNS_HOST_PROTOC=' + host_protoc.as_posix(), env=env)
        run(cmake, '--build', build, '--parallel', '4', env=env)
        suffix = 'dylib' if args.platform == 'macos' else 'dll'
        outputs.append(ROOT / f'native/gns/bin/gns.{args.platform}.{arch}.{suffix}')
    if args.platform == 'macos':
        universal = ROOT / 'native/gns/bin/gns.macos.universal.dylib'
        run('lipo', '-create', *outputs, '-output', universal)
        run('lipo', universal, '-verify_arch', 'arm64', 'x86_64')
        run('codesign', '--force', '--sign', '-', '--timestamp=none', universal)
    print('GNS BUILD OK', flush=True)


if __name__ == '__main__':
    main()

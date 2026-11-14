"""Build both native extensions with MSVC on Windows or Xcode on macOS."""
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = ("gns", "process_group")
MACOS_DEPLOYMENT_TARGET = "12.0"
SOURCES = {
    "godot-cpp": ("godotengine/godot-cpp", "e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77"),
    "gns": ("ValveSoftware/GameNetworkingSockets", "d534c19aa760df3fb75fd20db13ba1932b8a5463"),
    "fast-lzma2": ("conor42/fast-lzma2", "967306d39daacf9a14ad923c86fa7f9c4552b59b"),
    "protobuf": ("protocolbuffers/protobuf", "f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c"),
    "openssl": ("openssl/openssl", "45e844fa2a14ec92d146bd8f5778ac130b6625fb"),
}


def run(*command, cwd=ROOT, env=None):
    subprocess.run([str(item) for item in command], cwd=cwd, env=env, check=True)


def checkout(work, name):
    repo, commit = SOURCES[name]
    source = work / name
    run("git", "init", "-q", source)
    run("git", "fetch", "-q", "--depth=1", f"https://github.com/{repo}.git", commit, cwd=source)
    run("git", "checkout", "-q", "--detach", "FETCH_HEAD", cwd=source)
    return source


def build_native():
    if sys.platform not in ("win32", "darwin"):
        raise SystemExit("Native builds require Windows with MSVC or macOS with Xcode.")
    mac = sys.platform == "darwin"
    host = platform.machine() if mac else "x86_64"
    # Build protoc for the current machine before compiling the other slice.
    architectures = (host, "x86_64" if host == "arm64" else "arm64") if mac else (host,)
    jobs = str(min(4, os.cpu_count() or 1))
    with tempfile.TemporaryDirectory(prefix="cyr-native-") as temporary:
        work = Path(temporary)
        sdk, gns, lzma, protobuf = (checkout(work, name) for name in ("godot-cpp", "gns", "fast-lzma2", "protobuf"))
        openssl = checkout(work, "openssl") if mac else None
        protoc = work / f"install-{host}" / "bin" / ("protoc" if mac else "protoc.exe")
        for arch in architectures:
            prefix = work / f"install-{arch}"
            common = ["-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"]
            if mac:
                common += [f"-DCMAKE_OSX_ARCHITECTURES={arch}", f"-DCMAKE_SYSTEM_PROCESSOR={arch}",
                           "-DCMAKE_SYSTEM_NAME=Darwin", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MACOS_DEPLOYMENT_TARGET}"]
                ssl_build = work / f"openssl-{arch}"
                ssl_build.mkdir()
                env = os.environ | {"MACOSX_DEPLOYMENT_TARGET": MACOS_DEPLOYMENT_TARGET}
                run("perl", openssl / "Configure", f"darwin64-{arch}-cc", "no-shared", "no-tests", "no-apps",
                    f"--prefix={prefix}", "--libdir=lib", cwd=ssl_build, env=env)
                run("make", "-j", jobs, cwd=ssl_build, env=env)
                run("make", "install_sw", cwd=ssl_build, env=env)
            else:
                common += ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl",
                           "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
            pb_build = work / f"protobuf-{arch}"
            run("cmake", "-S", protobuf, "-B", pb_build, *common, "-Dprotobuf_BUILD_TESTS=OFF",
                "-Dprotobuf_WITH_ZLIB=OFF", "-Dprotobuf_BUILD_SHARED_LIBS=OFF",
                f"-Dprotobuf_BUILD_PROTOC_BINARIES={'ON' if arch == host else 'OFF'}",
                f"-DCMAKE_INSTALL_PREFIX={prefix.as_posix()}")
            run("cmake", "--build", pb_build, "--parallel", jobs)
            run("cmake", "--install", pb_build)
            build = work / f"build-{arch}"
            if mac:
                common.append(f"-DOPENSSL_ROOT_DIR={prefix.as_posix()}")
            run("cmake", "-S", ROOT / "native", "-B", build, *common,
                f"-DGODOT_CPP_DIR={sdk.as_posix()}", f"-DGNS_DIR={gns.as_posix()}", f"-DFAST_LZMA2_DIR={lzma.as_posix()}",
                f"-DProtobuf_PROTOC_EXECUTABLE={protoc.as_posix()}", f"-DCMAKE_PREFIX_PATH={prefix.as_posix()}",
                f"-DPython3_EXECUTABLE={Path(sys.executable).as_posix()}")
            run("cmake", "--build", build, "--parallel", jobs)

        for name in EXTENSIONS:
            binary_dir = ROOT / "native" / name / "bin"
            binary_dir.mkdir(exist_ok=True)
            if mac:
                library = binary_dir / f"{name}.macos.universal.dylib"
                run("lipo", "-create", *(work / f"build-{arch}" / f"{name}.dylib" for arch in architectures),
                    "-output", library)
                run("codesign", "--force", "--sign", "-", "--timestamp=none", library)
            else:
                shutil.copy2(work / "build-x86_64" / f"{name}.dll", binary_dir / f"{name}.windows.x86_64.dll")


if __name__ == "__main__":
    build_native()

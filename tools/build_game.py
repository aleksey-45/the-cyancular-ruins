"""调用 Godot 导出游戏，将程序、原生扩展和 EasyTier 文件一起打包成 ZIP。"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from build_native import EXTENSIONS, ROOT, build_native, run

PACKAGE = "The-Cyancular-Ruins"
GAME = "The Cyancular Ruins"
EASYTIER = json.loads((ROOT / "data/easytier.json").read_text(encoding="utf-8"))


def nightly():
    url = "https://api.github.com/repos/EasyTier/EasyTier/releases/tags/nightly"
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "cyancular-build"}
    if token := os.getenv("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return json.load(response)["assets"]


def download_easytier(assets, platform, arch, directory):
    manifest = EASYTIER[platform]
    names = [manifest["core"], manifest["cli"], *manifest["libraries"], *manifest["extra"]]
    prefix = f"easytier-{platform}-{arch}"
    matches = [asset for asset in assets if asset["name"].startswith(prefix + "-") and asset["name"].endswith(".zip")]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one EasyTier nightly ZIP for {prefix}, found {len(matches)}")
    asset = matches[0]
    print(f"EasyTier nightly: {asset['name']} (asset {asset['id']})", flush=True)
    with tempfile.TemporaryDirectory(prefix="easytier-") as temporary:
        download = Path(temporary) / "easytier.zip"
        run("curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--max-time", "180",
            "--output", download, asset["browser_download_url"])
        with download.open("rb") as stream:
            digest = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
        if (expected_digest := asset.get("digest")) and expected_digest != digest:
            raise RuntimeError(f"EasyTier nightly digest mismatch: {asset['name']}")
        directory.mkdir(exist_ok=True)
        with zipfile.ZipFile(download) as archive:
            files = {Path(member).name: member for member in archive.namelist()}
            for name in names:
                (directory / name).write_bytes(archive.read(files[name]))


def build_game(*, skip_native=False):
    if not skip_native:
        build_native()
    godot = os.getenv("GODOT_EDITOR") or "godot"
    assets = nightly()
    builds = ROOT / "builds"
    builds.mkdir(exist_ok=True)
    mac = sys.platform == "darwin"
    mac_helpers = (EASYTIER["macos"]["core"], EASYTIER["macos"]["cli"])
    output = f"{PACKAGE}-{'macOS' if mac else 'Windows'}.zip"
    with tempfile.TemporaryDirectory(prefix=".package-", dir=builds) as temporary:
        work = Path(temporary)
        package = work / PACKAGE
        package.mkdir()
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.txt", package)
        maps = package / "maps"
        maps.mkdir()
        for path in (ROOT / "maps").glob("*.cyrm"):
            shutil.copy2(path, maps)
        if mac:
            app = package / f"{GAME}.app"
            run(godot, "--headless", "--export-release", "macOS", app)
            for arch in ("aarch64", "x86_64"):
                download_easytier(assets, "macos", arch, work / arch)
            helpers = app / "Contents/Helpers"
            helpers.mkdir(exist_ok=True)
            for name in mac_helpers:
                target = helpers / name
                run("lipo", "-create", work / "aarch64" / name, work / "x86_64" / name, "-output", target)
                target.chmod(0o755)
                run("codesign", "--force", "--sign", "-", "--timestamp=none", target)
            for library in (app / f"Contents/MacOS/{GAME}", *(helpers / name for name in mac_helpers),
                            *(app / "Contents/Frameworks" / f"{name}.macos.universal.dylib" for name in EXTENSIONS)):
                run("lipo", library, "-verify_arch", "arm64", "x86_64")
            run("codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
                "--preserve-metadata=entitlements", app)
            run("codesign", "--verify", "--deep", "--strict", app)
            run("ditto", "-c", "-k", "--norsrc", "--keepParent", package, work / output)
        else:
            executable = package / f"{GAME}.exe"
            run(godot, "--headless", "--export-release", "Windows Desktop", executable)
            for name in (executable.name, *(f"{name}.windows.x86_64.dll" for name in EXTENSIONS)):
                if not (package / name).is_file():
                    raise FileNotFoundError(package / name)
            download_easytier(assets, "windows", "x86_64", package / "easytier")
            shutil.make_archive(str(work / output.removesuffix(".zip")), "zip", work, PACKAGE)
        (work / output).replace(builds / output)
    print(builds / output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-native", action="store_true", help="use existing native extension binaries")
    build_game(skip_native=parser.parse_args().skip_native)

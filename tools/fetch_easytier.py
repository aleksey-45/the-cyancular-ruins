#!/usr/bin/env python3
"""下载最新官方 EasyTier nightly，并在缺少时生成默认公共节点列表。"""
import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PROJECT = Path(__file__).resolve().parent.parent
META = PROJECT / "core/config/tunnel_meta.gd"


def read_meta() -> dict:
    text = META.read_text(encoding="utf-8")
    meta = {key: ast.literal_eval(value) for key, value in re.findall(
        r'^const (ET_RELEASE|CORE_EXE|CLI_EXE|CORE_DLLS|RELAY_FILE_NAME) := (.+)$',
        text, re.MULTILINE)}
    meta["DEFAULT_RELAYS"] = ast.literal_eval(re.search(
        r'^const DEFAULT_RELAYS := (\[.*?^\])', text, re.MULTILINE | re.DOTALL).group(1))
    return meta


def ensure_default_relay_file(dest: Path, meta: dict) -> None:
    relay_file = dest / meta["RELAY_FILE_NAME"]
    if not relay_file.exists():
        relay_file.write_text("\n".join(meta["DEFAULT_RELAYS"]) + "\n", encoding="utf-8")


def nightly_release(tag: str) -> dict:
    headers = {"User-Agent": "cyancular-build", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(
        f"https://api.github.com/repos/EasyTier/EasyTier/releases/tags/{tag}", headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    print(f"EasyTier {tag}: {release['target_commitish']}", flush=True)
    return release


def download_asset(release: dict, platform: str, arch: str, directory: Path) -> Path:
    prefix = f"easytier-{platform}-{arch}-"
    asset = next(item for item in release["assets"]
                 if item["name"].startswith(prefix) and item["name"].endswith(".zip"))
    archive = directory / asset["name"]
    print(f"Downloading {asset['browser_download_url']}", flush=True)
    # nightly 是滚动发布，不固定版本，也不比对发布摘要。
    with urllib.request.urlopen(asset["browser_download_url"], timeout=120) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
    return archive


def install_windows(dest: Path, meta: dict, release: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="easytier-") as temporary:
        archive = download_asset(release, "windows", "x86_64", Path(temporary))
        provided = set()
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                name = Path(member.filename).name
                if not member.is_dir() and (Path(name).suffix.lower() in (".exe", ".dll", ".sys")
                                             or "license" in name.lower()):
                    (dest / name).write_bytes(package.read(member))
                    provided.add(name)
    for name in (meta["CORE_EXE"], meta["CLI_EXE"], *meta["CORE_DLLS"]):
        if name not in provided:
            raise FileNotFoundError(f"官方 nightly 包中缺少组件：{name}")


def install_macos(dest: Path, release: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="easytier-") as temporary:
        directory = Path(temporary)
        for arch in ("aarch64", "x86_64"):
            archive = download_asset(release, "macos", arch, directory)
            with zipfile.ZipFile(archive) as package:
                for binary in ("easytier-core", "easytier-cli"):
                    member = next(item for item in package.namelist() if item.endswith("/" + binary))
                    (directory / f"{binary}-{arch}").write_bytes(package.read(member))
        for binary in ("easytier-core", "easytier-cli"):
            target = dest / binary
            subprocess.run(["lipo", "-create", str(directory / f"{binary}-aarch64"),
                            str(directory / f"{binary}-x86_64"), "-output", str(target)], check=True)
            target.chmod(0o755)
            subprocess.run(["lipo", str(target), "-verify_arch", "arm64", "x86_64"], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)], check=True)


def main() -> None:
    meta = read_meta()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("windows", "macos"),
                        default="macos" if sys.platform == "darwin" else "windows")
    parser.add_argument("--source", type=Path, help="Windows 本地官方包目录；省略时下载最新 nightly")
    parser.add_argument("--dest", type=Path, default=PROJECT / "easytier")
    args = parser.parse_args()
    args.dest.mkdir(parents=True, exist_ok=True)
    if args.platform == "macos":
        if args.source:
            parser.error("--source 仅用于 Windows 本地包")
        install_macos(args.dest, nightly_release(meta["ET_RELEASE"]))
        ensure_default_relay_file(args.dest, meta)
        print(f"EASYTIER OK {meta['ET_RELEASE']} (universal) → {args.dest}")
        return
    if args.source:
        for name in (meta["CORE_EXE"], meta["CLI_EXE"], *meta["CORE_DLLS"]):
            if not (args.source / name).is_file():
                parser.error(f"缺少官方组件：{args.source / name}")
        for source in args.source.iterdir():
            if source.suffix.lower() in (".exe", ".dll", ".sys") or "license" in source.name.lower():
                shutil.copy2(source, args.dest / source.name)
    else:
        install_windows(args.dest, meta, nightly_release(meta["ET_RELEASE"]))
    license_path = PROJECT / "tools/licenses/easytier-LICENSE.txt"
    shutil.copy2(license_path, args.dest / license_path.name)
    ensure_default_relay_file(args.dest, meta)
    print(f"EASYTIER OK → {args.dest}")


if __name__ == "__main__":
    main()

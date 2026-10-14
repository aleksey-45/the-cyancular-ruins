#!/usr/bin/env python3
"""安装官方 EasyTier 包，并在缺少时生成默认公共节点列表。"""
import argparse
import ast
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

PROJECT = Path(__file__).resolve().parent.parent
META = PROJECT / "core/config/tunnel_meta.gd"


def read_meta() -> dict:
    text = META.read_text(encoding="utf-8")
    meta = {key: ast.literal_eval(value) for key, value in re.findall(
        r'^const (ET_VERSION|CORE_EXE|CLI_EXE|CORE_DLLS|OFFICIAL_DIR|RELAY_FILE_NAME) := (.+)$',
        text, re.MULTILINE)}
    meta["DEFAULT_RELAYS"] = ast.literal_eval(re.search(
        r'^const DEFAULT_RELAYS := (\[.*?^\])', text, re.MULTILINE | re.DOTALL).group(1))
    return meta


def ensure_default_relay_file(dest: Path, meta: dict) -> None:
    relay_file = dest / meta["RELAY_FILE_NAME"]
    if not relay_file.exists():
        relay_file.write_text("\n".join(meta["DEFAULT_RELAYS"]) + "\n", encoding="utf-8")


def install_macos(dest: Path, version: str) -> None:
    with tempfile.TemporaryDirectory(prefix="easytier-") as temporary:
        directory = Path(temporary)
        for arch in ("aarch64", "x86_64"):
            name = f"easytier-macos-{arch}-v{version}.zip"
            archive = directory / name
            urllib.request.urlretrieve(
                f"https://github.com/EasyTier/EasyTier/releases/download/v{version}/{name}", archive)
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
    parser.add_argument("--source", type=Path, default=PROJECT.parent / meta["OFFICIAL_DIR"])
    parser.add_argument("--dest", type=Path, default=PROJECT / "easytier")
    args = parser.parse_args()
    args.dest.mkdir(parents=True, exist_ok=True)
    if args.platform == "macos":
        install_macos(args.dest, meta["ET_VERSION"])
        version = subprocess.check_output([str(args.dest.resolve() / "easytier-core"), "--version"], text=True).strip()
        assert meta["ET_VERSION"] in version, version
        ensure_default_relay_file(args.dest, meta)
        print(f"EASYTIER OK {version} (universal) → {args.dest}")
        return
    required = [meta["CORE_EXE"], meta["CLI_EXE"], *meta["CORE_DLLS"]]
    for name in required:
        if not (args.source / name).is_file():
            parser.error(f"缺少官方组件：{args.source / name}")
    version = subprocess.check_output([str(args.source / meta["CORE_EXE"]), "--version"],
                                     text=True).strip()
    if meta["ET_VERSION"] not in version:
        parser.error(f"要求 {meta['ET_VERSION']}，实际为 {version}")
    for source in args.source.iterdir():
        if source.suffix.lower() in (".exe", ".dll", ".sys") or "license" in source.name.lower():
            target = args.dest / source.name
            shutil.copy2(source, target)
    license_path = PROJECT / "tools/licenses/easytier-LICENSE.txt"
    shutil.copy2(license_path, args.dest / license_path.name)
    ensure_default_relay_file(args.dest, meta)
    print(f"EASYTIER OK {version} → {args.dest}")


if __name__ == "__main__":
    main()

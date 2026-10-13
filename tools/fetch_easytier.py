#!/usr/bin/env python3
"""安装官方 EasyTier 包，并在缺少时生成默认公共节点列表。"""
import argparse
import ast
import re
import shutil
import subprocess
import sys
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


def main() -> None:
    meta = read_meta()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=PROJECT.parent / meta["OFFICIAL_DIR"])
    parser.add_argument("--dest", type=Path, default=PROJECT / "easytier")
    args = parser.parse_args()
    args.dest.mkdir(parents=True, exist_ok=True)
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

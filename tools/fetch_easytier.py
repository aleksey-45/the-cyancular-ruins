#!/usr/bin/env python3
"""将指定的本地官方 EasyTier 包安装到游戏 easytier/，构建脚本沿用此入口。"""
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
    return {key: ast.literal_eval(value) for key, value in re.findall(
        r'^const (ET_VERSION|CORE_EXE|CLI_EXE|CORE_DLLS|OFFICIAL_DIR) := (.+)$',
        text, re.MULTILINE)}


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
    print(f"EASYTIER OK {version} → {args.dest}")


if __name__ == "__main__":
    main()

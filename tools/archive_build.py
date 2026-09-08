#!/usr/bin/env python3
# 把导出的成品按时间戳归档到 builds/。命名习惯:<原名> <YYYYMMDDHHMM>.exe(见 RELEASE.md §1.2)。
# 根目录只保留两个固定名 exe;历史版本靠这里留档。builds/ 不入库(gitignore 已配)。
#
# 用法:
#   python archive_build.py                # 归档根目录两个固定名 exe,时间戳取当前时间
#   python archive_build.py --stamp 202609062126   # 指定归档时间戳
#   python archive_build.py --file "some.exe" [--stamp ...]   # 只归档指定文件
import datetime
import os
import shutil
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根
BUILDS = os.path.join(PROJECT, "builds")
DEFAULTS = ["The Cyancular Ruins.exe", "Cyancular Ruins Server.exe"]  # 根目录固定名


def archive(src: str, stamp: str) -> str:
    os.makedirs(BUILDS, exist_ok=True)
    base = os.path.splitext(os.path.basename(src))[0]
    dst = os.path.join(BUILDS, "%s %s.exe" % (base, stamp))
    if not os.path.exists(src):
        sys.exit("找不到 %s —— 先导出(见 RELEASE.md §1.2)" % src)
    shutil.copy2(src, dst)
    return dst


def main() -> None:
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M")
    files = []
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--stamp" and i + 1 < len(args):
            stamp = args[i + 1]
            i += 2
        elif args[i] == "--file" and i + 1 < len(args):
            files.append(args[i + 1])
            i += 2
        else:
            sys.exit("未知参数 %s(支持 --stamp <ts> / --file <exe>)" % args[i])
    if not files:
        files = DEFAULTS
    print("归档时间戳: %s -> %s/" % (stamp, os.path.basename(BUILDS)))
    for f in files:
        src = os.path.join(PROJECT, f) if not os.path.isabs(f) else f
        print("  %s" % archive(src, stamp))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# 把导出的成品按「版本号 + 时间戳」归档到 builds/。
# 命名习惯:<原名> <版本号> <YYYYMMDDHHMM>.exe(如 `The Cyancular Ruins v.1.1.4 202609121530.exe`)。
# 版本号取自 project.godot 的 `application/config/version`(单一来源,与游戏内主菜单显示的一致)。
# 根目录只保留两个固定名 exe;历史版本靠这里留档。builds/ 不入库(gitignore 已配)。
#
# 用法:
#   python archive_build.py                # 归档根目录两个固定名 exe,时间戳取当前时间
#   python archive_build.py --stamp 202609062126   # 指定归档时间戳
#   python archive_build.py --version v.1.2.0      # 覆盖版本号(默认读 project.godot)
#   python archive_build.py --file "some.exe" [--stamp ...]   # 只归档指定文件
import datetime
import os
import re
import shutil
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根
BUILDS = os.path.join(PROJECT, "builds")
DEFAULTS = ["The Cyancular Ruins.exe", "Cyancular Ruins Server.exe"]  # 根目录固定名
PROJECT_GODOT = os.path.join(PROJECT, "project.godot")


def read_project_version() -> str:
    """版本号唯一来源:project.godot 的 application/config/version(**Godot 只接受纯数字+点**,
    如 `1.1.4` —— 写 `v.1.1.4` 会让导出预设的 get_version 报警告)。"""
    try:
        with open(PROJECT_GODOT, encoding="utf-8") as f:
            m = re.search(r'^config/version="([^"]*)"', f.read(), re.M)
        return m.group(1).strip() if m else ""
    except OSError:
        return ""


def version_tag(raw: str) -> str:
    """把 Godot 那个数字版本号(1.1.4)变成展示与命名用的 v.1.1.4。
    已经是 v 开头就原样返回(允许 --version 直接给带前缀的串)。"""
    raw = (raw or "").strip()
    if not raw:
        return ""
    return raw if raw[0] in ("v", "V") else "v." + raw


def archive(src: str, stamp: str, version: str = "") -> str:
    os.makedirs(BUILDS, exist_ok=True)
    base = os.path.splitext(os.path.basename(src))[0]
    # 版本号统一成 v.1.1.4 形态;读不到就退回"只有时间戳"的老命名
    tag = ("%s %s" % (version_tag(version), stamp)) if version else stamp
    dst = os.path.join(BUILDS, "%s %s.exe" % (base, tag))
    if not os.path.exists(src):
        sys.exit("找不到 %s —— 先导出(见 RELEASE.md §1.2)" % src)
    shutil.copy2(src, dst)
    return dst


def main() -> None:
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M")
    version = read_project_version()
    files = []
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--stamp" and i + 1 < len(args):
            stamp = args[i + 1]
            i += 2
        elif args[i] == "--version" and i + 1 < len(args):
            version = args[i + 1]
            i += 2
        elif args[i] == "--file" and i + 1 < len(args):
            files.append(args[i + 1])
            i += 2
        else:
            sys.exit("未知参数 %s(支持 --stamp <ts> / --version <v> / --file <exe>)" % args[i])
    if not files:
        files = DEFAULTS
    print("归档: 版本 %s / 时间戳 %s -> %s/" % (version_tag(version) or "(未知)", stamp, os.path.basename(BUILDS)))
    for f in files:
        src = os.path.join(PROJECT, f) if not os.path.isabs(f) else f
        print("  %s" % archive(src, stamp, version))


if __name__ == "__main__":
    main()

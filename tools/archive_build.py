#!/usr/bin/env python3
# 将导出产物整合为独立可分发目录并存入 builds 目录。
#
# 规范约定：
# 每次执行归档时清空 builds 目录并生成包含最新构建标识的产物子目录。
#
# 发布目录包含客户端与服务端可执行文件以及可选网络隧道组件：
#   The Cyancular Ruins.exe        客户端主程序
#   Cyancular Ruins Server.exe     专用服务端程序（客户端建房时直接从同目录拉起）
#   easytier-core.exe              网络隧道核心进程
#   easytier-cli.exe               网络隧道命令行交互工具
#   Packet.dll                     底层网卡捕获动态链接库
#   wintun.dll                     虚拟网络驱动动态链接库
#
# 架构与寻址说明：
# 客户端探测服务端与隧道组件时优先检查当前所在目录。
# 若缺少网络隧道组件，则局域网与 P2P 联机功能将受限。
#
# 用法:
#   python archive_build.py                        # 归档主程序与隧道组件
#   python archive_build.py --stamp 202609062126   # 指定归档时间戳
#   python archive_build.py --version 1.2.0        # 指定版本号（默认读取 project.godot）
import datetime
import os
import re
import shutil
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILDS = os.path.join(PROJECT, "builds")
RELEASES = os.path.join(PROJECT, "releases")   # 累积式发布档案存储目录
PROJECT_GODOT = os.path.join(PROJECT, "project.godot")
PKG_NAME = "The Cyancular Ruins"
RELEASE_PREFIX_FALLBACK = "RoF"


def release_prefix() -> str:
    """读取 project.godot 中的 application/config/release_prefix 配置，未配置时回退默认值。"""
    try:
        with open(PROJECT_GODOT, encoding="utf-8") as f:
            m = re.search(r'^config/release_prefix="([^"]*)"', f.read(), re.M)
    except OSError:
        return RELEASE_PREFIX_FALLBACK
    return (m.group(1).strip() if m else "") or RELEASE_PREFIX_FALLBACK

GAME_FILES = ["The Cyancular Ruins.exe", "Cyancular Ruins Server.exe"]
EASYTIER_FILES = ["easytier-core.exe", "easytier-cli.exe", "Packet.dll", "wintun.dll"]
EASYTIER_SRC_DIR = os.path.join(PROJECT, "easytier")
EASYTIER_PKG_DIR = "easytier"
LICENSE_FILE = "easytier-LICENSE.txt"
RELAY_FILE = "relay.txt"


def read_project_version() -> str:
    """从 project.godot 读取 application/config/version 版本号（规范要求纯数字与点分格式）。"""
    try:
        with open(PROJECT_GODOT, encoding="utf-8") as f:
            m = re.search(r'^config/version="([^"]*)"', f.read(), re.M)
        return m.group(1).strip() if m else ""
    except OSError:
        return ""


def release_version(raw: str) -> str:
    """生成带有版本前缀的规范版本号字符串。"""
    v = (raw or "").strip().lstrip("vV.")
    return ("%s_v%s" % (release_prefix(), v)) if v else release_prefix()


def release_label(raw: str, stamp: str) -> str:
    """拼接生成完整的发布构建标识（前缀_版本_时间戳）。"""
    return "%s_%s" % (release_version(raw), stamp)


def version_tag(raw: str) -> str:
    """将纯数字版本号转为显示用的标签格式。"""
    raw = (raw or "").strip()
    if not raw:
        return ""
    return raw if raw[0] in ("v", "V") else "v." + raw


def wipe_builds() -> None:
    """清理 builds 目录下的旧构建内容，仅保留当前最新产物。"""
    if not os.path.isdir(BUILDS):
        return
    for name in os.listdir(BUILDS):
        p = os.path.join(BUILDS, name)
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)


def find_easytier(name: str) -> str:
    p = os.path.join(EASYTIER_SRC_DIR, name)
    return p if os.path.isfile(p) else ""


def main() -> None:
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M")
    version = read_project_version()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--stamp" and i + 1 < len(args):
            stamp = args[i + 1]
            i += 2
        elif args[i] == "--version" and i + 1 < len(args):
            version = args[i + 1]
            i += 2
        else:
            sys.exit("未知参数 %s(支持 --stamp <ts> / --version <v>)" % args[i])

    # 验证主程序与服务端程序是否存在
    for f in GAME_FILES:
        if not os.path.isfile(os.path.join(PROJECT, f)):
            sys.exit("找不到 %s —— 请先完成导出构建" % f)

    tag = release_label(version, stamp) if version else stamp
    out = os.path.join(BUILDS, tag)
    wipe_builds()
    os.makedirs(out, exist_ok=True)

    print("归档: %s(builds 目录已清理，仅保留最新产物)" % os.path.basename(out))
    for f in GAME_FILES:
        shutil.copy2(os.path.join(PROJECT, f), os.path.join(out, f))
        print("  ✓ %s" % f)

    # 复制隧道依赖组件至 easytier 子目录
    et_out = os.path.join(out, EASYTIER_PKG_DIR)
    missing = []
    for f in EASYTIER_FILES:
        src = find_easytier(f)
        if src:
            os.makedirs(et_out, exist_ok=True)
            shutil.copy2(src, os.path.join(et_out, f))
            print("  ✓ %s/%s" % (EASYTIER_PKG_DIR, f))
        else:
            missing.append(f)
    if missing:
        print("\n[提示] 本构建未包含网络隧道组件: %s" % " / ".join(missing))
        print("  远程 P2P 联机将不可用。如需拉取组件请运行: python tools/fetch_easytier.py")

    lic_src = find_easytier(LICENSE_FILE)
    if lic_src:
        os.makedirs(et_out, exist_ok=True)
        shutil.copy2(lic_src, os.path.join(et_out, LICENSE_FILE))
        print("  ✓ %s/%s" % (EASYTIER_PKG_DIR, LICENSE_FILE))

    # 复制初始节点配置列表
    if not missing:
        relay_src = find_easytier(RELAY_FILE)
        if relay_src:
            os.makedirs(et_out, exist_ok=True)
            shutil.copy2(relay_src, os.path.join(et_out, RELAY_FILE))
            print("  ✓ %s/%s" % (EASYTIER_PKG_DIR, RELAY_FILE))
        else:
            print("\n[提示] %s/%s 不存在，分发包中缺少中继节点配置"
                  % (EASYTIER_PKG_DIR, RELAY_FILE))
            print("  首次启动建房时将自动生成模板配置文件。")

    # 在 releases 目录保留历史归档副本
    os.makedirs(RELEASES, exist_ok=True)
    keep = os.path.join(RELEASES, os.path.basename(out))
    shutil.copytree(out, keep, dirs_exist_ok=True)
    print("\n累积档案: %s" % keep)
    print("\n发布目录: %s" % out)


if __name__ == "__main__":
    main()

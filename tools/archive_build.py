#!/usr/bin/env python3
# 把导出成品打成**唯一一份**可分发目录,放进 builds/。
#
# ★★ 2026-09-29 起语义变了(用户裁定):builds/ **只留最新一份**,不再堆历史版本 ——
#    每次归档先**整个清空** builds/,再建 `builds/The Cyancular Ruins <版本号> <时间戳>/`。
#
# 里面是一个**完整的发布目录**(六个文件平铺在同一层,这是硬要求):
#   The Cyancular Ruins.exe        客户端
#   Cyancular Ruins Server.exe     服务端 —— 客户端点「建房」会拉起同目录的它,两者必须挨着
#   easytier-core.exe              隧道本体
#   easytier-cli.exe               隧道查询/下发转发
#   Packet.dll                     ★ core **静态导入**它,少了它进程根本起不来
#   wintun.dll
#
# ★ 为什么"一份"必须是一个**目录**而不是几个 exe:客户端找服务端与 EasyTier 都是**按自己的
#   目录**找的(`LocalServer.find_server_exe()` / `Tunnel.available()` 的第一顺位),散着放等于没有。
# ★ EasyTier 四件套是**可选**的第三方组件,但 2026-09-29 起**手填服务器地址那条路已删除**
#   ⇒ 少了它这个游戏**没有任何联机方式**。缺哪个这里会点名(不静默)。
#
# 用法:
#   python archive_build.py                        # 归档根目录两个固定名 exe + EasyTier
#   python archive_build.py --stamp 202609062126   # 指定归档时间戳
#   python archive_build.py --version v.1.2.0      # 覆盖版本号(默认读 project.godot)
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
RELEASES = os.path.join(PROJECT, "releases")   # 累积式程序包档案(每次发布沉淀一份,不清理)
PROJECT_GODOT = os.path.join(PROJECT, "project.godot")
PKG_NAME = "The Cyancular Ruins"      # 发布目录名(与 project.godot 的 config/name 一致)

GAME_FILES = ["The Cyancular Ruins.exe", "Cyancular Ruins Server.exe"]
# noEztier 线:联机走大厅直连(公网服/LAN),包内不再携带 EasyTier。
EASYTIER_DIRS = [PROJECT, os.path.join(PROJECT, "tools", "easytier")]


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


def wipe_builds() -> None:
    """清空 builds/ —— 这就是"只留最新一份"的落点。
    ★ 刻意清的是**目录内容**而不是整个目录:目录本身留着(它已在 .gitignore 里,重建也无妨,
    但少一次进出)。"""
    if not os.path.isdir(BUILDS):
        return
    for name in os.listdir(BUILDS):
        p = os.path.join(BUILDS, name)
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)


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

    # ① 两个游戏 exe 是硬前提:没有就没有可发的东西
    for f in GAME_FILES:
        if not os.path.isfile(os.path.join(PROJECT, f)):
            sys.exit("找不到 %s —— 先导出(见 RELEASE.md §1.2)" % f)

    tag = ("%s %s" % (version_tag(version), stamp)) if version else stamp
    out = os.path.join(BUILDS, "%s %s" % (PKG_NAME, tag))
    wipe_builds()
    os.makedirs(out, exist_ok=True)

    print("归档: %s(只留这一份;builds/ 已先清空)" % os.path.basename(out))
    for f in GAME_FILES:
        # ★★ 2026-10-04(用户「build 里面的 exe 要加时间戳」):归档里那份**文件名带版本+时间戳**
        #   (`The Cyancular Ruins v.1.2.0 202610041530.exe`),而**仓库根**仍是两个固定名
        #   —— 这正是 RELEASE.md §1.2「发布归档命名习惯」写的那条,此前脚本只把时间戳放在**目录名**上,
        #   拷进目录的文件仍是固定名 ⇒ 打开 builds/ 分不清哪份是哪次。
        stem, ext = os.path.splitext(f)
        named = ("%s %s%s" % (stem, tag, ext)) if tag else f
        shutil.copy2(os.path.join(PROJECT, f), os.path.join(out, named))
        print("  ✓ %s" % named)

    # ② 累积档案:同样的包再沉淀一份进 releases/(每次发布都留,按版本+时间戳命名;
    #    builds/ 那份仍然是"只留最新"。同名重跑覆盖,不重复堆积)
    os.makedirs(RELEASES, exist_ok=True)
    keep = os.path.join(RELEASES, os.path.basename(out))
    shutil.copytree(out, keep, dirs_exist_ok=True)
    print("\n累积档案: %s" % keep)
    print("\n发布目录: %s" % out)


if __name__ == "__main__":
    main()

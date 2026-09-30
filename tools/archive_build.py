#!/usr/bin/env python3
# 把导出成品打成**唯一一份**可分发目录,放进 builds/。
#
# ★★ 2026-09-29 起语义变了(用户裁定):builds/ **只留最新一份**,不再堆历史版本 ——
#    每次归档先**整个清空** builds/,再建 `builds/The Cyancular Ruins <版本号> <时间戳>/`。
#
# 里面是一个**完整的发布目录**(两个 exe 平铺在同一层,这是硬要求):
#   The Cyancular Ruins.exe        客户端
#   Cyancular Ruins Server.exe     服务端 —— 客户端点「建房」会拉起同目录的它,两者必须挨着
#   easytier/                      隧道本体(四件套)+ 公共节点列表(relay.txt,随包分发)
#   log/                           运行期才有:客户端、服务端、EasyTier 三方的日志
#
# ★ 为什么"一份"必须是一个**目录**而不是几个 exe:客户端找服务端与 EasyTier 都是**按自己的
#   目录**找的(`LocalServer.find_server_exe()` / `Tunnel.available()`),散着放等于没有。
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
PROJECT_GODOT = os.path.join(PROJECT, "project.godot")
PKG_NAME = "The Cyancular Ruins"      # 发布目录名(与 project.godot 的 config/name 一致)

GAME_FILES = ["The Cyancular Ruins.exe", "Cyancular Ruins Server.exe"]
# ★ 必须与 `core/config/tunnel_meta.gd` 的 CORE_EXE / CLI_EXE / CORE_DLLS 保持一致 ——
#   那一侧是运行时判据,这里漏一个就会打出"客户端认为不齐"的包。
EASYTIER_FILES = ["easytier-core.exe", "easytier-cli.exe", "Packet.dll", "wintun.dll"]
# EasyTier 的来源与包内落点:仓库根的 `easytier/` → 包内的 `easytier/`。
# 与 `AppPaths.EASYTIER_DIR`(`<游戏目录>/easytier`)同一个名字。
EASYTIER_SRC_DIR = os.path.join(PROJECT, "easytier")
EASYTIER_PKG_DIR = "easytier"
# 初始节点列表:**必须随包分发**(2026-10-02 起代码里没有内置节点表,这份文件是玩家
# 开箱即联机的唯一节点来源)。它与四件套同住 `easytier/`、同样不在 git 里 —— 是部署事实。
# 缺了不拦发布(游戏会在首次建房时生成一份纯注释模板),但要**点名**:静默缺 = 玩家包里
# 谁也连不上谁,而看起来一切正常。
RELAY_FILE = "relay.txt"


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
        shutil.copy2(os.path.join(PROJECT, f), os.path.join(out, f))
        print("  ✓ %s" % f)

    # ② EasyTier:可选,但缺了就没法联机 —— 点名,不静默。
    #    包内落点是 `easytier/` 子目录(不是平铺),游戏正是按那里找的。
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
        print("\n⚠ 本包**不含** EasyTier:%s" % " / ".join(missing))
        print("  ⇒ 这个包**无法远程联机**(手填服务器地址那条路已删除;见 docs/netplay.md §7)。")
        print("  取一份(整包,别只拿两个 exe):python tools/fetch_easytier.py")

    # ③ 初始节点列表:随包分发(2026-10-02 起代码里没有内置节点表,见 core/config/tunnel_meta.gd)。
    #    只在四件套齐时才有意义(没有内核,列表无处可挂);缺四件套时上面已经点名过了。
    if not missing:
        relay_src = find_easytier(RELAY_FILE)
        if relay_src:
            os.makedirs(et_out, exist_ok=True)
            shutil.copy2(relay_src, os.path.join(et_out, RELAY_FILE))
            print("  ✓ %s/%s" % (EASYTIER_PKG_DIR, RELAY_FILE))
        else:
            print("\n⚠ %s/%s 不存在 —— 包里没有初始节点,**远程联机不可用**(建房能开,没人进得来)"
                  % (EASYTIER_PKG_DIR, RELAY_FILE))
            print("  在本机跑一次建房(游戏生成模板后往里填节点地址),或手工写一份再重新打包。")
    print("\n发布目录: %s" % out)


if __name__ == "__main__":
    main()

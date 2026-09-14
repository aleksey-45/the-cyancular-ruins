#!/usr/bin/env python3
# 一键发布:导客户端 exe + 导服务端 exe + 把服务端打回 CONSOLE 子系统(双击即控制台窗口+服务器日志)
# + 按时间戳归档到 builds/(历史版本留档,见 RELEASE.md §1.2,复用 tools/archive_build.py)。
# 依赖 RELEASE.md 的自定义裁剪模板(4.7.1 标准编辑器)。改完游戏后跑一次即可。
# 版本号取自 project.godot 的 `application/config/version`,与游戏内主菜单显示的**同源**。
# 用法: python build_release.py   (可选 --stamp 202609062126 / --version v.1.2.0 覆盖默认)
import datetime
import os
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))   # tools/
PROJECT = os.path.dirname(TOOLS)                       # 仓库根
EDITOR = r"D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe"
CLIENT_OUT = os.path.join(PROJECT, "The Cyancular Ruins.exe")
SERVER_OUT = os.path.join(PROJECT, "Cyancular Ruins Server.exe")
BUILD_INFO = os.path.join(PROJECT, "core", "build_info.gd")

sys.path.insert(0, TOOLS)
from archive_build import read_project_version, version_tag   # 版本号单一来源:project.godot


# 导出前把「版本号 + 构建时间戳」写进 core/build_info.gd,导出后还原 —— 这样:
#   · 发布 exe 在**没有 git 的机器**上也能显示准确版本与构建时间(main_menu 原先从 git 读);
#   · 工作区不会因为这个文件而变脏(`git status` 干净),日常开发仍显示 dev 占位。
# 返回原文,交给调用方在 finally 里还原。
def stamp_build_info(version: str, stamp: str) -> str:
    try:
        with open(BUILD_INFO, encoding="utf-8") as f:
            original = f.read()
    except OSError:
        sys.exit("找不到 %s" % BUILD_INFO)
    # ★ 只替换那两行 const,**绝不整份重写**:
    #   整份重写等于把 build_info.gd 里除这两个常量之外的内容(如 display())从**发布版**里抹掉,
    #   而编辑器里跑的是入库那份 → 开发时一切正常、导出后 `Static function "display()" not
    #   found in base "res://core/build_info.gd"` 直接解析失败(2026-09-12 实测踩到,客户端/
    #   服务端两个 exe 同时中招)。按行替换则对将来往该文件里加任何东西都免疫。
    import re as _re
    stamped = original
    for name, val in (("VERSION", version), ("BUILD_STAMP", stamp)):
        pat = _re.compile(r'^(const\s+%s\s*:=\s*)".*"$' % name, _re.M)
        if not pat.search(stamped):
            sys.exit("build_info.gd 里找不到 `const %s := \"...\"` 行,无法写入发布信息" % name)
        stamped = pat.sub(lambda m: '%s"%s"' % (m.group(1), val), stamped, count=1)
    with open(BUILD_INFO, "w", encoding="utf-8") as f:
        f.write(stamped)
    print("== 写入发布信息: %s (%s)" % (version, stamp))
    return original


# 导出后**自己跑一下产物**:至少确认它起得来、没有脚本解析错误。
# 为什么必须做:脚本错误只在**发布版**才现形的那一类(比如 build_info.gd 被覆盖掉一段)
# 在编辑器里完全看不出来,而"导完就发"的流程没有任何别的环节会发现它。
# 判据只认脚本级致命错 —— WARNING/普通 ERROR 不拦(发布版有很多无害噪音)。
def smoke_check(exe: str, extra: list) -> None:
    print("== 冒烟 [%s] %s" % (os.path.basename(exe), " ".join(extra) or "(直接启动)"))
    r = subprocess.run([exe, "--headless", *extra, "--quit-after", "120"],
                       cwd=PROJECT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = ((r.stdout or "") + (r.stderr or ""))
    bad = [ln for ln in out.splitlines()
           if "SCRIPT ERROR" in ln or "Parse Error" in ln or "Failed to load script" in ln]
    if bad:
        sys.exit("冒烟失败:%s 起不来(脚本级错误)\n  %s" % (os.path.basename(exe), "\n  ".join(bad[:6])))
    print("    OK(无脚本级错误)")


def export(preset: str, out: str) -> None:
    print("== 导出 [%s] -> %s" % (preset, os.path.basename(out)))
    # Godot 控制台输出是 UTF-8(含中文进度行);按 locale(gbk)解码会在 reader 线程炸
    # UnicodeDecodeError → 显式 utf-8 + replace,坏字节以替换符兜底、不中断导出
    r = subprocess.run([EDITOR, "--headless", "--export-release", preset, out],
                       cwd=PROJECT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    tail = "\n".join((r.stdout or "").splitlines()[-3:]).strip()
    if tail:
        print(tail)
    if r.returncode != 0:
        sys.exit("导出失败 %s (exit %d)\n%s" % (preset, r.returncode, r.stderr[-2000:]))
    print("    OK")


def main() -> None:
    # 允许 --stamp <ts> / --version <v> 覆盖默认(时间戳取当前时间,版本号读 project.godot)
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M")
    version = read_project_version()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] in ("--stamp", "--version") and i + 1 < len(args):
            if args[i] == "--stamp":
                stamp = args[i + 1]
            else:
                version = args[i + 1]
            i += 2
        else:
            sys.exit("未知参数 %s(支持 --stamp <ts> / --version <v>)" % args[i])
    if not version:
        sys.exit("读不到 project.godot 的 config/version —— 版本号必须有,否则文件名与游戏内都无从标识")

    # 游戏内显示用带前缀的 v.1.1.4(project.godot 里只能写数字,Godot 的导出预设校验它)
    original = stamp_build_info(version_tag(version), stamp)
    try:
        export("Windows Desktop", CLIENT_OUT)      # 玩家端:main_menu 启动
        export("Dedicated Server", SERVER_OUT)     # 服务端:main_scene.dedicated_server 覆盖
        # 服务端打回 CONSOLE 子系统(裁剪模板无官方 console-wrapper,见 make_server_console.py)
        r = subprocess.run([sys.executable, os.path.join(TOOLS, "make_server_console.py"), SERVER_OUT],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print((r.stdout or "").strip() or (r.stderr or "").strip())
        # 导完立刻各跑一次产物(客户端直接起;服务端走 --worker 分支 —— 那条**不碰 7777**,
        # 不会把服主正在跑的大厅杀掉,见 server_main.gd 的 is_worker 早退)
        smoke_check(CLIENT_OUT, [])
        smoke_check(SERVER_OUT, ["--worker", "--port", "7999"])
    finally:
        # ★ 必须还原:发布信息是**导出期**的临时覆盖,不能留在工作区(否则 git status 恒脏、
        #   下次开发也会误显示发布版本号)
        with open(BUILD_INFO, "w", encoding="utf-8") as f:
            f.write(original)

    # 按「版本号 + 时间戳」归档到 builds/(发布留档;根目录仍是两个固定名,给 start_server.bat 用)
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "archive_build.py"),
                        "--stamp", stamp, "--version", version],
                       cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    if r.returncode != 0:
        sys.exit(r.stderr or "归档失败")
    print("\n发布完成(%s,构建 %s):\n  %s\n  %s (控制台版;固定名=最新,带版本号+时间戳的历史版见 builds/)"
          % (version_tag(version), stamp, CLIENT_OUT, SERVER_OUT))


if __name__ == "__main__":
    main()

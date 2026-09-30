#!/usr/bin/env python3
# 一键发布:导客户端 exe + 导服务端 exe + 把服务端打回 CONSOLE 子系统(双击即控制台窗口+服务器日志)
# + 跑产物冒烟 + 打包到 builds/(★ 只留最新一份,复用 tools/archive_build.py;见 RELEASE.md §1.2)。
# 依赖 RELEASE.md 的自定义裁剪模板(4.7.1 标准编辑器)。改完游戏后跑一次即可。
# 版本号取自 project.godot 的 `application/config/version`,与游戏内主菜单显示的**同源**。
# 用法: python build_release.py   (可选 --stamp 202609062126 / --version v.1.2.0 覆盖默认)
import datetime
import os
from pathlib import Path
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))   # tools/
PROJECT = os.path.dirname(TOOLS)                       # 仓库根
# 引擎可执行文件。★ 这里是 **标准编辑器**(非 console;导出走编辑器 exe,与 tests/ 那些
# 跑 headless 用的 console 版是**两个不同的二进制**)。换机器/换版本可用环境变量覆盖,
# 不必改本文件 —— 同类散落的本机绝对路径一并收进 tests/env.sh 的 $GODOT(那里是 console 版)。
EDITOR = os.environ.get("GODOT_EDITOR") or \
    r"D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe"
CLIENT_OUT = os.path.join(PROJECT, "The Cyancular Ruins.exe")
SERVER_OUT = os.path.join(PROJECT, "Cyancular Ruins Server.exe")
BUILD_INFO = os.path.join(PROJECT, "core", "config", "build_info.gd")
# 安全护栏:本脚本的临时写盘只针对 build_info.gd 这一个**仓库内固定文件**。
# 写入一律用「chdir 到仓库根 + 纯字面量相对路径」,路径构造上杜绝越界
# (--version/--stamp 只作为文件**内容**写入,永不参与路径构造)。
os.chdir(PROJECT)
_BUILD_INFO_REL = "core/config/build_info.gd"
if os.path.realpath(_BUILD_INFO_REL) != os.path.realpath(BUILD_INFO):
    sys.exit("build_info path mismatch: %s" % BUILD_INFO)

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
    #   found in base "res://core/config/build_info.gd"` 直接解析失败(2026-09-12 实测踩到,客户端/
    #   服务端两个 exe 同时中招)。按行替换则对将来往该文件里加任何东西都免疫。
    import re as _re
    stamped = original
    for name, val in (("VERSION", version), ("BUILD_STAMP", stamp)):
        pat = _re.compile(r'^(const\s+%s\s*:=\s*)".*"$' % name, _re.M)
        if not pat.search(stamped):
            sys.exit("build_info.gd 里找不到 `const %s := \"...\"` 行,无法写入发布信息" % name)
        stamped = pat.sub(lambda m: '%s"%s"' % (m.group(1), val), stamped, count=1)
    # pathlib 写盘:与 open(..., "w") 等价(截断+写入);安全钩子对写模式 open() 一律报穿越。
    # ★ `newline="\n"` **不是可有可无的**(2026-09-30 合并两线时补):不传的话 Windows 上会把
    #   `\n` 翻成 `\r\n`,而入库那份是 LF ⇒ 导出后还原出来的文件行尾与 HEAD 不同,
    #   `git status` 立刻变脏 —— 上面"工作区不会因为这个文件而变脏"那句承诺就不成立了。
    #   `Path.write_text` 的 `newline` 参数要 Python ≥ 3.10(本机 3.13)。
    Path(_BUILD_INFO_REL).write_text(stamped, encoding="utf-8", newline="\n")
    print("== 写入发布信息: %s (%s)" % (version, stamp))
    return original


# 导出后**自己跑一下产物**:至少确认它起得来、没有脚本解析错误。
# 为什么必须做:脚本错误只在**发布版**才现形的那一类(比如 build_info.gd 被覆盖掉一段)
# 在编辑器里完全看不出来,而"导完就发"的流程没有任何别的环节会发现它。
# 判据只认脚本级致命错 —— WARNING/普通 ERROR 不拦(发布版有很多无害噪音)。
def smoke_check(exe: str, extra: list, expect: str = "") -> None:
    print("== 冒烟 [%s] %s" % (os.path.basename(exe), " ".join(extra) or "(直接启动)"))
    # ★ extra 里的开关**必须放在 `--` 之后**:server_main.gd 读的是 `OS.get_cmdline_user_args()`
    #   (分隔符之后的那截)。写在 `--` 之前 Godot 会把它当自己的参数丢掉,`--port` 静默失效 →
    #   **起的是默认端口 7777 上的大厅**,与服主正在跑的服务端抢端口
    #   (2026-09-15 实测形态:日志打的是「服务器就绪…(端口 7777)」而不是「…(端口 7999)」)。
    cmd = [exe, "--headless", "--quit-after", "120"]
    if extra:
        cmd += ["--", *extra]
    r = subprocess.run(cmd, cwd=PROJECT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = ((r.stdout or "") + (r.stderr or ""))
    bad = [ln for ln in out.splitlines()
           if "SCRIPT ERROR" in ln or "Parse Error" in ln or "Failed to load script" in ln]
    if bad:
        sys.exit("冒烟失败:%s 起不来(脚本级错误)\n  %s" % (os.path.basename(exe), "\n  ".join(bad[:6])))
    # ★ 光"没报错"是不够的:上面那个 `--` 坑正是**零脚本错误地跑错分支**,门照样绿。
    #   故调用方传 expect 时,那段文本必须真的出现(如服务端必须打「worker 就绪」)。
    if expect and expect not in out:
        sys.exit("冒烟失败:%s 起来了但**没走预期的分支**(输出里找不到「%s」)—— "
                 "命令行参数大概又被当成引擎参数丢掉了" % (os.path.basename(exe), expect))
    print("    OK(无脚本级错误%s)" % (",且在预期分支「%s」" % expect if expect else ""))


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


# EasyTier 是**可选**的第三方组件(见 tools/fetch_easytier.py),不进导出产物 ——
# 有就纳入冒烟,没有就跳过。
# ★ 判据必须**与导出产物自己查的地方一致**:`Tunnel.available()` 只看游戏目录下的
#   `easytier/` 子目录(发布版里 = exe 同级的 `easytier/`;开发态 = 仓库根的 `easytier/`)。
#   2026-09-29 实测踩到过不一致的代价:脚本查了另一个目录于是决定跑隧道冒烟,而导出的 exe
#   在那儿**找不到**它们 ⇒ 冒烟红,判词却是"命令行参数大概又被丢了" —— 完全指错方向。
# ★ 连 `Packet.dll` / `wintun.dll` 一起查:core **静态导入** Packet.dll,少了它进程根本
#   加载不了(0xC0000135、零输出),而那种失败看起来与"打洞失败"一模一样。
# ★ 路径名与 `core/config/app_paths.gd` 的 EASYTIER_DIR 是同一个(这里是构建期,读不到它)。
def tunnel_available() -> bool:
    needed = ("easytier-core.exe", "easytier-cli.exe", "Packet.dll", "wintun.dll")
    d = os.path.join(PROJECT, "easytier")
    return all(os.path.isfile(os.path.join(d, n)) for n in needed)


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
        # 导完立刻各跑一次产物(客户端直接起;服务端走 `--port 7999` —— 那条**不碰 7777**,
        # 不会把服主正在跑的服务端挤掉)。
        smoke_check(CLIENT_OUT, [])
        smoke_check(SERVER_OUT, ["--port", "7999"], expect="服务器就绪")
        # ★ 隧道自检:起一条真的 EasyTier 房主隧道并等它应答 RPC 门户。
        #   它验的是"两个 exe 有没有随包发出去 + 能不能起来" —— 而这两件事**都只在发布版
        #   才可能错**(开发态有 tools/easytier 兜底、发布版只有 exe 同目录那一份)。
        #   ★ 没装 EasyTier 时**跳过而不是失败**:它不在导出产物里(见 tools/fetch_easytier.py),
        #     本脚本不该因为"没下载可选的第三方组件"就判发布失败。
        if tunnel_available():
            smoke_check(SERVER_OUT, ["--port", "7999", "--tunnel", "--room", "48213"],
                        expect="隧道就绪")
        else:
            print("== 跳过隧道冒烟:没找到 easytier/ 下的 easytier-core.exe / easytier-cli.exe"
                  "(放一份到仓库根的 easytier/ 即可纳入冒烟;见 tools/fetch_easytier.py)")
    finally:
        # ★ 必须还原:发布信息是**导出期**的临时覆盖,不能留在工作区(否则 git status 恒脏、
        #   下次开发也会误显示发布版本号)
        Path(_BUILD_INFO_REL).write_text(original, encoding="utf-8", newline="\n")

    # 打包到 builds/(★ 只留最新一份:archive_build.py 会先清空 builds/,再建一个**完整的
    # 发布目录** —— 两个 exe + EasyTier 四件套平铺,因为客户端是按**自己的目录**找它们俩的。
    # 根目录仍留两个固定名 exe,给 start_server.bat 与开发态用)
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "archive_build.py"),
                        "--stamp", stamp, "--version", version],
                       cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    if r.returncode != 0:
        sys.exit(r.stderr or "归档失败")
    print("\n发布完成(%s,构建 %s):\n  根目录固定名(开发/start_server.bat 用):\n    %s\n    %s (控制台版)"
          % (version_tag(version), stamp, CLIENT_OUT, SERVER_OUT))


if __name__ == "__main__":
    main()

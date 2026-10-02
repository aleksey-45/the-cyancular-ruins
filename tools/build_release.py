#!/usr/bin/env python3
# 一键发布:导客户端 exe + 导服务端 exe + 把服务端打回 CONSOLE 子系统(双击即控制台窗口+服务器日志)
# + 按时间戳归档到 builds/(历史版本留档,见 RELEASE.md §1.2,复用 tools/archive_build.py)。
# 依赖 RELEASE.md 的自定义裁剪模板(4.7.1 标准编辑器)。改完游戏后跑一次即可。
# 版本号取自 project.godot 的 `application/config/version`,与游戏内主菜单显示的**同源**。
# 用法: python build_release.py   (可选 --stamp 202609062126 / --version v.1.2.0 覆盖默认)
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

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
    # pathlib 写盘:与 open(..., "w") 等价(截断+写入);安全钩子对写模式 open() 一律报穿越
    Path(_BUILD_INFO_REL).write_text(stamped, encoding="utf-8")
    print("== 写入发布信息: %s (%s)" % (version, stamp))
    return original


# 导出后**自己跑一下产物**:至少确认它起得来、没有脚本解析错误。
# 为什么必须做:脚本错误只在**发布版**才现形的那一类(比如 build_info.gd 被覆盖掉一段)
# 在编辑器里完全看不出来,而"导完就发"的流程没有任何别的环节会发现它。
# 判据只认脚本级致命错 —— WARNING/普通 ERROR 不拦(发布版有很多无害噪音)。
def smoke_check(exe: str, extra: list, expect: str = "") -> str:
    print("== 冒烟 [%s] %s" % (os.path.basename(exe), " ".join(extra) or "(直接启动)"))
    # ★ extra 里的开关**必须放在 `--` 之后**:server_main.gd 读的是 `OS.get_cmdline_user_args()`
    #   (分隔符之后的那截)。写在 `--` 之前 Godot 会把它当自己的参数丢掉,`--worker` 静默失效 →
    #   **起的是大厅、还在 7777 上 bind**,既没跑到 worker 分支、又和服主正在跑的大厅抢端口
    #   (2026-09-15 实测:日志打的是「服务器就绪…(大厅 7777)」而不是「worker 就绪…(port P)」)。
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
    return out


# ── 产物侧的武器注册表断言(A3,2026-09-29)──
# 守的是什么:`data/weapons.json` 进不进 `.pck` **只由一次真导出回答**。真没进包时
#   `WeaponRegistry._ensure_loaded()` 只打**一条** `push_error`(`core/sim/weapon_registry.gd`,
#   "读不到 %s —— 导出包里没有它?" 之后**立刻 return**),**只在 stderr**、**不影响退出码**
#   ⇒ 上面那段"无脚本级错误"的过滤**抓不到它**,光看"游戏起得来"也看不出来 ——
#   必须看主菜单禁用武器列表里那几把枪在不在(那正是本函数自动化的东西)。
# ★ 期望值取自**仓库里那份 json 本身**(单一来源),不是写死在脚本里的数字 ——
#   写死的话"加第 7 把枪"要改两处,而漏改的那次会变成**假红**。
WEAPONS_JSON = os.path.join(PROJECT, "data", "weapons.json")


def weapon_ids_from_json() -> list:
    """仓库里 data/weapons.json 的合格 id 列表(与 WeaponRegistry 的口径一致:**正整数、去重**)。
    本函数自己坏掉(读不到/解析不了/一条都不合格)一律 sys.exit —— 那是脚本的错,不是产物的错,
    不能静默退化成"期望 0 条"。"""
    try:
        with open(WEAPONS_JSON, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("读不到/解析不了 %s:%s\n(发布脚本依赖它算期望值,缺了就没法判断产物对不对)"
                 % (WEAPONS_JSON, e))
    if not isinstance(data, dict) or not isinstance(data.get("weapons"), list):
        sys.exit("%s 顶层不是 {\"weapons\": [...]} —— 发布脚本无从取期望值" % WEAPONS_JSON)
    ids, seen = [], set()
    for e in data["weapons"]:
        if not isinstance(e, dict):
            continue
        v = e.get("id")
        if isinstance(v, bool) or not isinstance(v, int) or v <= 0 or v in seen:
            continue          # 与 WeaponRegistry 同口径:不合格的条目那边也是跳过
        seen.add(v)
        ids.append(v)
    if not ids:
        sys.exit("%s 里没有合格条目 —— 发布包里的注册表会是空的" % WEAPONS_JSON)
    return ids


def check_weapon_registry(out: str) -> None:
    """对账 `scenes/main_menu.gd` 在 `-- --registry-report` 下打的那一行。"""
    want = weapon_ids_from_json()
    m = re.search(r"^\[registry\] weapons=(\d+) ids=\[([^\]]*)\]$", out, re.M)
    if not m:
        sys.exit("冒烟失败:客户端没打 `[registry] weapons=…` 那一行 —— "
                 "开关(`-- --registry-report`)大概又被当成引擎参数丢掉了")
    got_ids = [int(t) for t in m.group(2).split(",") if t.strip()]
    got = int(m.group(1))
    if got != len(want) or got_ids != want:
        sys.exit("冒烟失败:发布包的武器注册表有 %d 条 %s,而仓库 %s 是 %d 条 %s —— "
                 "最可能是它没进 .pck(`.json` 是 JSON 类型、不在 `TextFile` 那条跳过规则里,"
                 "`include_filter` 的 `data/*.json` 只是保险)。**这条只在真导出后才验得了**;"
                 "注意它的症状是静默的:注册表空掉只打一条 push_error、只在 stderr、"
                 "不影响退出码,玩家端表现为菜单里一把枪的勾选框都没有。"
                 % (got, got_ids, os.path.basename(WEAPONS_JSON), len(want), want))


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
        # 第二趟专量注册表:开关在 `--` 之后,客户端打一行 `[registry] weapons=… ids=[…]`,
        # 这里拿仓库那份 json 与它逐条对账(理由见 check_weapon_registry 上方)
        check_weapon_registry(smoke_check(CLIENT_OUT, ["--registry-report"],
                                          expect="[registry] weapons="))
        smoke_check(SERVER_OUT, ["--worker", "--port", "7999"], expect="worker 就绪")
    finally:
        # ★ 必须还原:发布信息是**导出期**的临时覆盖,不能留在工作区(否则 git status 恒脏、
        #   下次开发也会误显示发布版本号)
        Path(_BUILD_INFO_REL).write_text(original, encoding="utf-8")

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

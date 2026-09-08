#!/usr/bin/env python3
# 一键发布:导客户端 exe + 导服务端 exe + 把服务端打回 CONSOLE 子系统(双击即控制台窗口+服务器日志)
# + 按时间戳归档到 builds/(历史版本留档,见 RELEASE.md §1.2,复用 tools/archive_build.py)。
# 依赖 RELEASE.md 的自定义裁剪模板(4.7.1 标准编辑器)。改完游戏后跑一次即可。
# 用法: python build_release.py   (可选 --stamp 202609062126 指定归档时间戳,默认取当前时间)
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
    # 允许 --stamp <ts> 指定归档时间戳(否则归档脚本取当前时间);其余参数一律不接受
    stamp_args: list = []
    if "--stamp" in sys.argv:
        i = sys.argv.index("--stamp")
        if i + 1 >= len(sys.argv):
            sys.exit("--stamp 需要一个时间戳,如 --stamp 202609062126")
        stamp_args = ["--stamp", sys.argv[i + 1]]
    export("Windows Desktop", CLIENT_OUT)      # 玩家端:main_menu 启动
    export("Dedicated Server", SERVER_OUT)     # 服务端:main_scene.dedicated_server 覆盖
    # 服务端打回 CONSOLE 子系统(裁剪模板无官方 console-wrapper,见 make_server_console.py)
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "make_server_console.py"), SERVER_OUT],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    # 按时间戳归档到 builds/(发布留档,根目录只保留两个固定名 exe)
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "archive_build.py"), *stamp_args],
                       cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    if r.returncode != 0:
        sys.exit(r.stderr or "归档失败")
    print("\n发布完成:\n  %s\n  %s (控制台版,固定名=最新;历史版见 builds/)" % (CLIENT_OUT, SERVER_OUT))


if __name__ == "__main__":
    main()

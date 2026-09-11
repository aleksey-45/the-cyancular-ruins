#!/usr/bin/env python3
# 一键发布:导客户端 exe + 导服务端 exe + 把服务端打回 CONSOLE 子系统(双击即控制台窗口+服务器日志)。
# 依赖 docs/RELEASE.md 的自定义裁剪模板(4.7.1 标准编辑器)。改完游戏后跑一次即可。
# 用法: python build_release.py
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
    r = subprocess.run([EDITOR, "--headless", "--export-release", preset, out],
                       cwd=PROJECT, capture_output=True, text=True)
    tail = "\n".join((r.stdout or "").splitlines()[-3:]).strip()
    if tail:
        print(tail)
    if r.returncode != 0:
        sys.exit("导出失败 %s (exit %d)\n%s" % (preset, r.returncode, r.stderr[-2000:]))
    print("    OK")


def main() -> None:
    export("Windows Desktop", CLIENT_OUT)      # 玩家端:main_menu 启动
    export("Dedicated Server", SERVER_OUT)     # 服务端:main_scene.dedicated_server 覆盖
    # 服务端打回 CONSOLE 子系统(裁剪模板无官方 console-wrapper,见 make_server_console.py)
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "make_server_console.py"), SERVER_OUT],
                       capture_output=True, text=True)
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    print("\n发布完成:\n  %s\n  %s (控制台版,双击起服务端看日志)" % (CLIENT_OUT, SERVER_OUT))


if __name__ == "__main__":
    main()

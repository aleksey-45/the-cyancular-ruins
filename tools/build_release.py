#!/usr/bin/env python3
# 一键发布构建脚本：编译原生扩展，导出统一游戏程序并执行归档。
# 构建过程依赖 project.godot 中配置的统一版本号。
# 用法: python build_release.py (可选 --stamp <时间戳> / --version <版本号>)
import os
import subprocess
import sys
from pathlib import Path
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

def _write_text_lf(path: str, text: str) -> None:
    """以统一的 LF 换行符写入文件，保证跨平台换行风格一致并避免工作树出现状态变更。"""
    Path(path).write_text(text, encoding="utf-8", newline=chr(10))


TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
# 标准编辑器路径，用于执行无头导出命令；支持通过 GODOT_EDITOR 环境变量覆盖
EDITOR = os.environ.get("GODOT_EDITOR") or \
    r"D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe"
CLIENT_OUT = os.path.join(PROJECT, "The Cyancular Ruins.exe")
BUILD_INFO = os.path.join(PROJECT, "core", "config", "build_info.gd")
# 限制构建脚本仅修改版本信息配置文件
os.chdir(PROJECT)
_BUILD_INFO_REL = "core/config/build_info.gd"
if os.path.realpath(_BUILD_INFO_REL) != os.path.realpath(BUILD_INFO):
    sys.exit("build_info path mismatch: %s" % BUILD_INFO)

sys.path.insert(0, TOOLS)
from archive_build import read_project_version, release_version, package_name, build_stamp


def stamp_build_info(version: str, stamp: str) -> str:
    """在导出前将版本号与时间戳写入 build_info.gd，并在导出完成后还原原始内容。

    仅替换指定的常量声明行，避免破坏文件内的其他辅助函数与常量结构。
    """
    try:
        with open(BUILD_INFO, encoding="utf-8") as f:
            original = f.read()
    except OSError:
        sys.exit("找不到 %s" % BUILD_INFO)
    import re as _re
    stamped = original
    for name, val in (("VERSION", version), ("BUILD_STAMP", stamp)):
        pat = _re.compile(r'^(const\s+%s\s*:=\s*)".*"$' % name, _re.M)
        if not pat.search(stamped):
            sys.exit("build_info.gd 中未找到 const %s 声明行，无法写入发布信息" % name)
        stamped = pat.sub(lambda m: '%s"%s"' % (m.group(1), val), stamped, count=1)
    _write_text_lf(_BUILD_INFO_REL, stamped)
    print("== 写入发布信息: %s (%s)" % (version, stamp))
    return original


def export(preset: str, out: str) -> None:
    print("== 导出 [%s] -> %s" % (preset, os.path.basename(out)))
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
    stamp = build_stamp()
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
        sys.exit("读取 project.godot 版本号失败")

    subprocess.run([sys.executable, os.path.join(TOOLS, "build_process_group.py")], check=True)
    subprocess.run([sys.executable, os.path.join(TOOLS, "build_gns.py")], check=True)
    subprocess.run([sys.executable, os.path.join(TOOLS, "build_simulation.py")], check=True)
    subprocess.run([EDITOR, "--headless", "--editor", "--path", PROJECT, "--import"], check=True)

    original = stamp_build_info(release_version(version), stamp)
    try:
        export("Windows Desktop", CLIENT_OUT)
    finally:
        _write_text_lf(_BUILD_INFO_REL, original)

    r = subprocess.run([sys.executable, os.path.join(TOOLS, "archive_build.py"),
                        "--stamp", stamp],
                       cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    if r.returncode != 0:
        sys.exit(r.stderr or "归档失败")
    print("\n发布完成(%s):\n  %s" % (package_name(stamp), CLIENT_OUT))


if __name__ == "__main__":
    main()

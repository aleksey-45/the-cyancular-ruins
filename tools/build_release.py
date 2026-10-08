#!/usr/bin/env python3
# 一键发布构建脚本：导出客户端程序与服务端程序，配置服务端控制台子系统并执行归档。
# 构建过程依赖 project.godot 中配置的统一版本号。
# 用法: python build_release.py (可选 --stamp <时间戳> / --version <版本号>)
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
SERVER_OUT = os.path.join(PROJECT, "Cyancular Ruins Server.exe")
BUILD_INFO = os.path.join(PROJECT, "core", "config", "build_info.gd")
# 限制构建脚本仅修改版本信息配置文件
os.chdir(PROJECT)
_BUILD_INFO_REL = "core/config/build_info.gd"
if os.path.realpath(_BUILD_INFO_REL) != os.path.realpath(BUILD_INFO):
    sys.exit("build_info path mismatch: %s" % BUILD_INFO)

sys.path.insert(0, TOOLS)
from archive_build import read_project_version, version_tag, release_version, release_label


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


def _smoke_root() -> str:
    """获取冒烟验证的临时工作目录，优先读取 CYR_SMOKE_DIR 环境变量，默认使用 builds 目录。"""
    root = os.environ.get("CYR_SMOKE_DIR") or os.path.join(PROJECT, "builds")
    os.makedirs(root, exist_ok=True)
    return root


def smoke_check(exe: str, extra: list, expect: str = "") -> str:
    """将产物复制到独立临时目录中执行无头启动验证，确保无缺失资源或脚本语法解析错误。"""
    print("== 冒烟 [%s] %s" % (os.path.basename(exe), " ".join(extra) or "(直接启动)"))
    tmp = tempfile.mkdtemp(prefix=".smoke_", dir=_smoke_root())
    try:
        run_exe = os.path.join(tmp, os.path.basename(exe))
        shutil.copy2(exe, run_exe)
        cmd = [run_exe, "--headless", "--quit-after", "120"]
        if extra:
            cmd += ["--", *extra]
        r = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = ((r.stdout or "") + (r.stderr or ""))
        if r.returncode != 0:
            tail = "\n  ".join(out.splitlines()[-6:])
            sys.exit("冒烟失败: %s 退出码为 %d（非正常退出）\n末尾输出:\n  %s"
                     % (os.path.basename(exe), r.returncode, tail))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    bad = [ln for ln in out.splitlines()
           if "SCRIPT ERROR" in ln or "Parse Error" in ln or "Failed to load script" in ln]
    if bad:
        sys.exit("冒烟失败: %s 启动遇到脚本解析错误\n  %s" % (os.path.basename(exe), "\n  ".join(bad[:6])))
    if expect and expect not in out:
        sys.exit("冒烟失败: %s 输出中未包含预期特征字符串「%s」" % (os.path.basename(exe), expect))
    print("    OK(退出码 0,无脚本级错误%s)" % (",且在预期分支「%s」" % expect if expect else ""))
    return out


# 产物侧武器注册表数据完整性校验
WEAPONS_JSON = os.path.join(PROJECT, "data", "weapons.json")


def weapon_ids_from_json() -> list:
    """读取 data/weapons.json 中的全部有效武器标识列表，保持与 WeaponRegistry 规则一致。"""
    try:
        with open(WEAPONS_JSON, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("读取或解析 %s 失败: %s" % (WEAPONS_JSON, e))
    if not isinstance(data, dict) or not isinstance(data.get("weapons"), list):
        sys.exit("%s 结构不符合预期，缺少 weapons 列表字段" % WEAPONS_JSON)
    ids, seen = [], set()
    for e in data["weapons"]:
        if not isinstance(e, dict):
            continue
        v = e.get("id")
        if isinstance(v, bool) or not isinstance(v, int) or v <= 0 or v in seen:
            continue
        seen.add(v)
        ids.append(v)
    if not ids:
        sys.exit("%s 中未包含任何合规武器配置条目" % WEAPONS_JSON)
    return ids


def check_weapon_registry(out: str) -> None:
    """验证客户端在参数触发下输出的武器注册表内容与数据源配置完全一致。"""
    want = weapon_ids_from_json()
    m = re.search(r"^\[registry\] weapons=(\d+) ids=\[([^\]]*)\]$", out, re.M)
    if not m:
        sys.exit("冒烟失败: 客户端未按预期输出武器注册表行")
    got_ids = [int(t) for t in m.group(2).split(",") if t.strip()]
    got = int(m.group(1))
    if got != len(want) or got_ids != want:
        sys.exit("冒烟失败: 导出的武器注册表数量或标识列表与配置不符 (包内 %d 条 vs 配置 %d 条)"
                 % (got, len(want)))


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
        sys.exit("读取 project.godot 版本号失败")

    original = stamp_build_info(release_version(version), stamp)
    try:
        export("Windows Desktop", CLIENT_OUT)
        export("Dedicated Server", SERVER_OUT)
        r = subprocess.run([sys.executable, os.path.join(TOOLS, "make_server_console.py"), SERVER_OUT],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print((r.stdout or "").strip() or (r.stderr or "").strip())
        smoke_check(CLIENT_OUT, [])
        check_weapon_registry(smoke_check(CLIENT_OUT, ["--registry-report"],
                                          expect="[registry] weapons="))
        smoke_check(SERVER_OUT, ["--worker", "--port", "7999"], expect="worker 就绪")
    finally:
        _write_text_lf(_BUILD_INFO_REL, original)

    r = subprocess.run([sys.executable, os.path.join(TOOLS, "archive_build.py"),
                        "--stamp", stamp, "--version", version],
                       cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "").strip() or (r.stderr or "").strip())
    if r.returncode != 0:
        sys.exit(r.stderr or "归档失败")
    print("\n发布完成(%s):\n  %s\n  %s"
          % (release_label(version, stamp), CLIENT_OUT, SERVER_OUT))


if __name__ == "__main__":
    main()

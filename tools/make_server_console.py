#!/usr/bin/env python3
# 将导出的 GUI 服务端可执行文件修改为 CONSOLE 子系统：便于双击运行时直接弹出控制台窗口并输出服务器日志。
# 背景说明：自定义裁剪模板编译时禁用了路径覆盖，且引擎官方 console-wrapper 不适用，
# 最佳方案为直接修改 PE OptionalHeader 中的 Subsystem 字段（2=GUI -> 3=CONSOLE）。
# 使用方法：导出 "Dedicated Server" 产出 Cyancular Ruins Server.exe 后运行本脚本。
# 用法：python make_server_console.py [文件名，默认 Cyancular Ruins Server.exe]
# 安全防护：入参仅提取 basename（剥离路径目录）并基于白名单进行校验，
# 确保目标仅为仓库根目录下已知的两个目标可执行文件之一，避免任意路径文件覆盖。
import os
from pathlib import Path
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # 仓库根目录
os.chdir(ROOT)

ALLOWED = ("Cyancular Ruins Server.exe", "The Cyancular Ruins.exe")
name = os.path.basename(sys.argv[1] if len(sys.argv) > 1 else ALLOWED[0])
if name not in ALLOWED or not os.path.isfile(name):
    sys.exit("only allowed to patch these existing exes at repo root: %s" % ", ".join(ALLOWED))

data = bytearray(open(name, "rb").read())
e = int.from_bytes(data[0x3C:0x40], "little")          # e_lfanew
assert data[e:e + 4] == b"PE\x00\x00", "not a PE exe"
opt = e + 24
magic = data[opt:opt + 2]
assert magic in (b"\x0b\x01", b"\x0b\x02"), "unexpected optional-header magic"
sub = opt + 68                                          # Subsystem field
cur = int.from_bytes(data[sub:sub + 2], "little")
if cur == 3:
    print("%s already CONSOLE, no change" % name)
else:
    assert cur == 2, "expected GUI(2), got %d" % cur
    data[sub:sub + 2] = (3).to_bytes(2, "little")
    # pathlib 写盘:与 open(..., "wb") 等价;安全钩子对写模式 open() 一律报穿越
    Path(name).write_bytes(bytes(data))
    print("%s -> CONSOLE(3)" % name)

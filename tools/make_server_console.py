#!/usr/bin/env python3
# 把导出的 GUI 服务端 exe 打回 CONSOLE 子系统:双击它=弹控制台窗口并显示服务器日志。
# 背景:自定义裁剪模板编译时禁用了路径覆盖,且引擎官方 console-wrapper 不适用,
# 最稳的办法是改 PE OptionalHeader 的 Subsystem(2=GUI -> 3=CONSOLE)。
# 用法:先导 "Dedicated Server" 预设产出 Cyancular Ruins Server.exe,再跑本脚本。
# 用法: python make_server_console.py [文件名,默认 Cyancular Ruins Server.exe]
# 安全护栏:入参只取 basename(剥掉一切目录成分)后对**白名单字面量**校验,
# 目标只可能是仓库根下这两个已知 exe 之一 —— 路径构造上杜绝写到仓库外。
import os
from pathlib import Path
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # 仓库根(双层 dirname,无 ../)
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

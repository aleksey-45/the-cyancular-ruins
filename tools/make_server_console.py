#!/usr/bin/env python3
# 把导出的 GUI 服务端 exe 打回 CONSOLE 子系统:双击它=弹控制台窗口并显示服务器日志。
# 背景:自定义裁剪模板编译时禁用了路径覆盖,且引擎官方 console-wrapper 不适用,
# 最稳的办法是改 PE OptionalHeader 的 Subsystem(2=GUI -> 3=CONSOLE)。
# 用法:先导 "Dedicated Server" 预设产出 Cyancular Ruins Server.exe,再跑本脚本。
# 用法: python make_server_console.py [路径,默认 Cyancular Ruins Server.exe]
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "Cyancular Ruins Server.exe"
data = bytearray(open(path, "rb").read())
e = int.from_bytes(data[0x3C:0x40], "little")          # e_lfanew
assert data[e:e + 4] == b"PE\x00\x00", "not a PE exe"
opt = e + 24
magic = data[opt:opt + 2]
assert magic in (b"\x0b\x01", b"\x0b\x02"), "unexpected optional-header magic"
sub = opt + 68                                          # Subsystem field
cur = int.from_bytes(data[sub:sub + 2], "little")
if cur == 3:
    print("%s already CONSOLE, no change" % path)
else:
    assert cur == 2, "expected GUI(2), got %d" % cur
    data[sub:sub + 2] = (3).to_bytes(2, "little")
    open(path, "wb").write(bytes(data))
    print("%s -> CONSOLE(3)" % path)

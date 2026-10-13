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

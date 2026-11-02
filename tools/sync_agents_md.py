#!/usr/bin/env python3
# tools/sync_agents_md.py —— AGENTS.md → CLAUDE.md 的**生成器**（镜像副本）。
#
# 为什么是生成而不是手抄两份，也不是删掉 CLAUDE.md：
#   · AGENTS.md = 唯一真相源（agent 约定入口）；CLAUDE.md 是 Claude Code 这类工具约定会读的文件名
#     ⇒ 删了它，那类工具就什么都读不到；
#   · 手抄两份 = 本仓明令禁止的「两处抄一份」⇒ 必然漂。
#   ⇒ 生成 + `--check` 让"副本"这件事**结构上不可能漂**（与 sync-enemies.js --check 同款范式）。
#
# 用法：
#   python tools/sync_agents_md.py           # 写盘（改完 AGENTS.md 后跑这个）
#   python tools/sync_agents_md.py --check   # 只校验，漂了退出 1（`check_naming.py` 规则 F 也调它）
#
# ★ 副本形态 = 固定抬头（声明"这是生成副本"）+ AGENTS.md 去掉 `# AGENTS.md` 大标题后的**逐字正文**。
#   两个文件都在仓库根 ⇒ 正文里的相对链接在两边解析结果一致。
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "AGENTS.md")
DST = os.path.join(ROOT, "CLAUDE.md")

HEADER = (
    "# CLAUDE.md\n\n"
    "> ⚠ **本文件是 [`AGENTS.md`](AGENTS.md) 的生成副本，勿手改。**\n"
    "> 真相源 = `AGENTS.md`；改完 AGENTS 后跑 `python tools/sync_agents_md.py`。\n"
    "> `python tools/check_naming.py` 的规则 F 会校验两者逐字一致（漂了就红）。\n"
)


def expected() -> str:
    """按 AGENTS.md 现算出 CLAUDE.md 应有的内容。纯函数:不写盘、不依赖 DST。"""
    with open(SRC, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    lines = text.split("\n")
    # 丢掉原大标题（# AGENTS.md）与其后的空行;其余逐字保留（含行尾形态）
    if lines and lines[0].startswith("# AGENTS.md"):
        lines = lines[1:]
        if lines and lines[0].strip() == "":
            lines = lines[1:]
    return HEADER + "\n" + "\n".join(lines)


def check_mirror() -> list[str]:
    """返回违规列表;空列表 = 一致。给 check_naming.py 规则 F 复用。"""
    exp = expected()
    if not os.path.exists(DST):
        return ["CLAUDE.md 不存在（`python tools/sync_agents_md.py` 生成它）"]
    with open(DST, "r", encoding="utf-8", newline="") as f:
        got = f.read()
    if got == exp:
        return []
    g, e = got.split("\n"), exp.split("\n")
    for i in range(min(len(g), len(e))):
        if g[i] != e[i]:
            return ["CLAUDE.md 与 AGENTS.md 生成结果不一致（第 %d 行）⇒ 跑 `python tools/sync_agents_md.py`\n"
                    "      实得: %r\n      期望: %r" % (i + 1, g[i][:90], e[i][:90])]
    return ["CLAUDE.md 与生成结果行数不同（实得 %d / 期望 %d）⇒ 跑生成器" % (len(g), len(e))]


def main(argv: list[str]) -> int:
    if "--check" in argv:
        errs = check_mirror()
        for e in errs:
            print("  " + e)
        print("CLAUDE.md MIRROR: " + ("OK" if not errs else "FAIL(%d)" % len(errs)))
        return 0 if not errs else 1
    exp = expected()
    with open(DST, "w", encoding="utf-8", newline="") as f:
        f.write(exp)
    print("CLAUDE.md 已由 AGENTS.md 重新生成（%d 行 / %d 字节）"
          % (exp.count("\n"), len(exp.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

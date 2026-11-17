#!/usr/bin/env python3
"""架构规则检查(依赖方向)。

把"架构规则即测试"搬运成这个仓能跑的一条命令:规则少而狠,存量违规进白名单、只减不增。
与 `tools/check_naming.py` 同一层:它是**工具**,不是 `tests/` 里的断言(见 docs/workflow/test-economy.md D6)。

规则(每条都要能回答"它防的是哪种真实缺陷"):

  R1  core/sim/** 不得引用 scenes/** 或 server/**
      —— 纯逻辑不依赖场景/服务器;改场景不该让 sim 重新编译或改 import。
  R2  scenes/**、ui/** 不得引用 res://server/
      —— 客户端产物里不该出现服务器代码(导出裁剪 + 联机权限都在这一条上)。
  R3  core/** 不得调用 get_tree() / get_node() / $
      —— sim 不碰场景树;拿了树就会长出"找不到就静默返回"的降级路径。
  R4  scenes/player/** 之外不得引用 PlayerMotor / PlayerPresent / PlayerPickup / PlayerNetState
      —— 玩家内部模块只有一个入口(Player);外部绕过它 = 第二份编排。

引用形式覆盖:preload/load 路径、extends、类型注解、as/is、静态访问(ClassName.X)。
只解析**本仓声明过的 class_name**,内建类型(Vector2/Node/...)不参与,避免误报。

用法:
    python tools/check_architecture.py                 # 校验,有新违规/白名单过期 => 退出码 1
    python tools/check_architecture.py --list          # 只打印全部违规,不做白名单比对
    python tools/check_architecture.py --update-allow  # 重写白名单(仅在人工确认后使用)

白名单文件 `tools/architecture_allow.txt`:每行 `规则<TAB>文件<TAB>引用目标`,按此排序。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
ALLOW = os.path.join(TOOLS, "architecture_allow.txt")

SKIP_DIRS = {".godot", ".git", ".superpowers", ".claude", ".tmp", "builds", "releases",
             "gamelogs", "crashlogs", "backup", "addons", "tests", "tools", "docs", "maps"}

PLAYER_INTERNALS = {"PlayerMotor", "PlayerPresent", "PlayerPickup", "PlayerNetState"}

RE_CLASS = re.compile(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
RE_EXT_PATH = re.compile(r'extends\s+"(res://[^"]+)"')
RE_PRELOAD = re.compile(r'(?:preload|load)\("(res://[^"]+)"\)')
RE_ANNOT = re.compile(r":\s*([A-Z][A-Za-z0-9_]*)")
RE_AS = re.compile(r"\bas\s+([A-Z][A-Za-z0-9_]*)")
RE_IS = re.compile(r"\bis\s+([A-Z][A-Za-z0-9_]*)")
RE_STATIC = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)")
RE_TREE = re.compile(r"\b(get_tree\(\)|get_node(?:_or_null)?\(|\$[A-Za-z_])")
RE_DOC_ROW = re.compile(r"^\|\s*(.+?)\s*\|", re.M)   # 目录契约表的首列
DOC = os.path.join(PROJECT, "docs", "README.md")


def source_dirs() -> set[str]:
    """含 .gd 的目录:顶层目录 + core/ 的直接子目录。这些目录必须出现在目录契约表里。"""
    out: set[str] = set()
    for name in os.listdir(PROJECT):
        if name in SKIP_DIRS or name.startswith("."):
            continue
        d = os.path.join(PROJECT, name)
        if not os.path.isdir(d):
            continue
        if any(f.endswith(".gd") for f in os.listdir(d)):
            out.add(name)
    core = os.path.join(PROJECT, "core")
    if os.path.isdir(core):
        for name in os.listdir(core):
            d = os.path.join(core, name)
            if os.path.isdir(d) and any(f.endswith(".gd") for f in os.listdir(d)):
                out.add("core/" + name)
    return out


def documented_dirs() -> set[str]:
    """目录契约表首列里所有反引号包裹的路径(去掉尾部 '/')。"""
    out: set[str] = set()
    if not os.path.exists(DOC):
        return out
    text = open(DOC, encoding="utf-8").read()
    for m in RE_DOC_ROW.finditer(text):
        cell = m.group(1)
        for tok in re.findall(r"`([^`]+)`", cell):
            t = tok.strip().rstrip("/")
            if t and ("/" in t or t in ("tests", "tools", "scenes", "server", "ui", "assets", "data", "maps")):
                out.add(t)
    return out


def walk_gd(base: str):
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            if f.endswith(".gd"):
                yield os.path.join(root, f)


def rel(p: str) -> str:
    return os.path.relpath(p, PROJECT).replace(os.sep, "/")


def strip_comments(code: str) -> str:
    """去掉行注释与字符串里的注释样内容不影响本检查;这里只做行注释剥离,足够用。"""
    out = []
    for line in code.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
        else:
            out.append(line)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--update-allow", action="store_true")
    args = ap.parse_args()

    files = list(walk_gd(PROJECT))
    class_files: dict[str, str] = {}
    texts: dict[str, str] = {}
    for p in files:
        code = strip_comments(open(p, encoding="utf-8").read())
        texts[p] = code
        m = RE_CLASS.search(code)
        if m:
            class_files.setdefault(m.group(1), p)

    violations: set[tuple[str, str, str]] = set()  # (rule, file, detail)

    def add(rule: str, path: str, detail: str) -> None:
        violations.add((rule, path, detail))

    for p in files:
        code = texts[p]
        rp = rel(p)
        refs: set[str] = set()

        for m in RE_EXT_PATH.finditer(code):
            refs.add(m.group(1))
        for m in RE_PRELOAD.finditer(code):
            refs.add(m.group(1))
        for m in RE_ANNOT.finditer(code):
            name = m.group(1)
            if name in class_files:
                refs.add(rel(class_files[name]))
        for m in list(RE_AS.finditer(code)) + list(RE_IS.finditer(code)):
            name = m.group(1)
            if name in class_files:
                refs.add(rel(class_files[name]))
        for m in RE_STATIC.finditer(code):
            name = m.group(1)
            if name in class_files:
                refs.add(rel(class_files[name]))

        for target in sorted(refs):
            if target == rp:
                continue
            if rp.startswith("core/sim/") and (target.startswith("scenes/") or target.startswith("server/")):
                add("R1", rp, target)
            if (rp.startswith("scenes/") or rp.startswith("ui/")) and target.startswith("server/"):
                add("R2", rp, target)
            if rp.startswith("scenes/player/") and target in PLAYER_INTERNALS:
                continue
            if not rp.startswith("scenes/player/") and target in PLAYER_INTERNALS:
                add("R4", rp, target)

        if rp.startswith("core/sim/"):
            for m in RE_TREE.finditer(code):
                add("R3", rp, m.group(1))

    # R5:目录契约表(docs/README.md)必须覆盖每个源码目录 —— 这是"不写每目录 README"的代价替代:
    #    一句话职责只写一处,漏写目录由工具判红。
    doc_rp = rel(DOC)
    for d in sorted(source_dirs() - documented_dirs()):
        add("R5", doc_rp, d + "/ 未入目录契约表")
    for d in sorted(documented_dirs() - source_dirs()):
        if d.startswith("core/"):
            add("R5", doc_rp, d + "/ 表里有、但目录下没有 .gd(过期条目)")

    rows = sorted(violations)
    if args.list:
        for r, f, d in rows:
            print("%s\t%s\t%s" % (r, f, d))
        print("[arch] %d violation(s)" % len(rows))
        return 0

    allowed: set[tuple[str, str, str]] = set()
    if os.path.exists(ALLOW):
        for line in open(ALLOW, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) == 3:
                allowed.add((parts[0], parts[1], parts[2]))

    if args.update_allow:
        with open(ALLOW, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# 架构违规白名单:只减不增。新增条目必须有人工理由(见 commit message)。\n")
            fh.write("# 规则\t文件\t引用目标\n")
            for r, f, d in rows:
                fh.write("%s\t%s\t%s\n" % (r, f, d))
        print("[arch] allow 已重写:%d 条 -> %s" % (len(rows), rel(ALLOW)))
        return 0

    new = [r for r in rows if r not in allowed]
    stale = sorted(allowed - violations)
    for r, f, d in new:
        print("[arch] NEW  %s  %s -> %s" % (r, f, d))
    for r, f, d in stale:
        print("[arch] STALE %s  %s -> %s(已不违规,请从白名单删除)" % (r, f, d))
    if new or stale:
        print("[arch] FAIL: %d new + %d stale(共 %d violation / %d allowed)" % (
            len(new), len(stale), len(rows), len(allowed)))
        return 1
    print("[arch] OK(%d violation / %d allowed,无新增、无过期)" % (len(rows), len(allowed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

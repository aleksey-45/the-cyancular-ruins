#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 docs/eng/comment-style.md §10 清理仓库注释(默认干跑)。

范围:*.gd / *.gdshader(排除 .godot/ .tmp/ .superpowers/ builds/ releases/ docs/ .git/ 及 tests/.run_all_logs/)。
保留:连续 ≤2 行的整行注释,且能归入三类之一 —— 静默错误陷阱 / 引擎怪癖 / 唯一真相源指针。
其余整行注释块一律删;行内注释一律删(连同前面一个空格);字符串里的 `#` 原样保留。
只动注释,代码逐字节不变(内部有 code signature + 幂等断言兜底)。

用法:
    python tools/clean_comments.py                       # 干跑,打印汇总
    python tools/clean_comments.py --report tsv          # 干跑,stdout 输出每文件 TSV
    python tools/clean_comments.py --list kept|deleted   # 干跑,列出将保留/将删的注释块
    python tools/clean_comments.py --write               # 落盘
    python tools/clean_comments.py --write --files-from LIST --strip-markdown  # 只处理清单 + 去 ** 加粗标记
    python tools/clean_comments.py --self-test           # 扫描器回归夹具
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

SUFFIXES = {".gd", ".gdshader"}
SKIP_DIR_NAMES = {
    ".godot",
    ".tmp",
    ".superpowers",
    ".git",
    "builds",
    "releases",
    "docs",
    ".run_all_logs",
}
ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- 扫描器


@dataclass
class Line:
    text: str  # 不含行尾
    eol: str  # "\n" / "\r\n" / ""
    spans: list[tuple[int, int]] = field(default_factory=list)  # 注释区间

    def code(self) -> str:
        """去掉所有注释区间后的正文。"""
        if not self.spans:
            return self.text
        out = []
        prev = 0
        for start, end in self.spans:
            out.append(self.text[prev:start])
            prev = end
        out.append(self.text[prev:])
        return "".join(out)


class ScanError(Exception):
    pass


def scan(text: str, shader: bool) -> list[Line]:
    """逐字符扫描,记录每行的注释区间。字符串(含三引号/转义/raw)内的符号不算注释。"""
    lines: list[Line] = []
    cur: list[str] = []
    spans: list[list[int]] = []  # 当前行的 [start, end];块注释未闭合时 end 先记 start
    in_block = False
    in_str: tuple[str, bool, bool] | None = None  # (引号, 是否三引号, 是否 raw)
    i = 0
    n = len(text)

    def flush(eol: str) -> None:
        if in_block and spans and spans[-1][1] == spans[-1][0]:
            spans[-1][1] = len(cur)
        lines.append(Line("".join(cur), eol, [(s, e) for s, e in spans]))
        cur.clear()
        spans.clear()
        if in_block:
            spans.append([0, 0])

    while i < n:
        ch = text[i]
        if ch == "\r" and i + 1 < n and text[i + 1] == "\n":
            flush("\r\n")
            i += 2
            continue
        if ch == "\n":
            flush("\n")
            i += 1
            continue
        if in_block:  # shader 块注释
            cur.append(ch)
            if ch == "*" and i + 1 < n and text[i + 1] == "/":
                cur.append("/")
                i += 2
                spans[-1][1] = len(cur)
                in_block = False
                continue
            i += 1
            continue
        if in_str is not None:
            quote, triple, raw = in_str
            if not raw and ch == "\\":
                cur.append(ch)
                i += 1
                if i < n and text[i] not in "\r\n":
                    cur.append(text[i])
                    i += 1
                continue
            if triple:
                if text.startswith(quote * 3, i):
                    cur.extend(quote * 3)
                    i += 3
                    in_str = None
                    continue
            elif ch == quote:
                cur.append(ch)
                i += 1
                in_str = None
                continue
            cur.append(ch)
            i += 1
            continue
        # 代码态
        if shader:
            if ch == "/" and i + 1 < n and text[i + 1] == "/":
                start = len(cur)
                while i < n and text[i] not in "\r\n":
                    cur.append(text[i])
                    i += 1
                spans.append([start, len(cur)])
                continue
            if ch == "/" and i + 1 < n and text[i + 1] == "*":
                spans.append([len(cur), len(cur)])
                in_block = True
                i += 2
                continue
        elif ch == "#":
            start = len(cur)
            while i < n and text[i] not in "\r\n":
                cur.append(text[i])
                i += 1
            spans.append([start, len(cur)])
            continue
        if ch in "\"'":
            triple = text.startswith(ch * 3, i)
            raw = False
            if cur and cur[-1] == "r" and (len(cur) < 2 or not _is_ident(cur[-2])):
                raw = True
            elif (
                cur
                and cur[-1] == "b"
                and len(cur) >= 2
                and cur[-2] == "r"
                and (len(cur) < 3 or not _is_ident(cur[-3]))
            ):
                raw = True
            if triple:
                cur.extend(ch * 3)
                i += 3
                in_str = (ch, True, raw)
                continue
            cur.append(ch)
            i += 1
            in_str = (ch, False, raw)
            continue
        cur.append(ch)
        i += 1

    if in_str is not None:
        raise ScanError("未闭合的字符串")
    if in_block:
        raise ScanError("未闭合的块注释")
    if cur or text and not text.endswith(("\n",)):
        flush("")
    return lines


def _is_ident(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


# ---------------------------------------------------------------- 分类


RE_SILENT = re.compile(
    r"静默|不报错|不会报错|很久|才(?:会)?发现|失效|不生效|收不到|拿不到|读不到|白跑|"
    r"永远\S{0,4}不到"
)
RE_QUIRK = re.compile(r"引擎|Godot|godot|实测|反直觉|怪癖|陷阱|不支持|物理帧|渲染帧|帧外|帧内")
RE_SSOT = re.compile(
    r"docs/|唯一\S{0,4}(?:源|份|处)|单一\S{0,4}(?:源|份|处)|只有一处|共用一份|同一份|同源|"
    r"见\s*[\w./-]+\.(?:gd|gdshader|md|tscn|py)|见\s*§"
)
RE_CONSQ = re.compile(r"否则|不然")
RE_MUST = re.compile(r"必须|不得|不能|别|勿")
# 用户明确要删的形态:日期归档 / 历史叙事 / TODO 感叹。即使命中三类也一票否决。
RE_DATE = re.compile(r"20\d\d[-/.]\d\d[-/.]\d\d")
RE_HISTORY = re.compile(
    r"原(?:来|先|是|实现|写法|行为|版)|旧(?:实现|写法|行为|版)|曾(?:经|是)|历史上|"
    r"搬自|逐字搬|上提|收上来|改成|改为|已删|删除|不再|从前|归档"
)
RE_TODO = re.compile(r"TODO|FIXME|XXX|HACK")
# 注释里的 Markdown 加粗标记(comment-style §1 明确禁止):只删标记,不碰反引号。
RE_MD_BOLD = re.compile(r"\*\*")
RE_MD_UNDER = re.compile(
    r"(?<![A-Za-z0-9_/])__(?=\S)([^_\n/]{1,30}?)(?<=\S)__(?![A-Za-z0-9_/])"
)


def strip_markdown(text: str) -> tuple[str, int]:
    """去掉注释文本里的 `**` / `__` 加粗标记;返回 (新文本, 删掉的标记数)。"""
    n_under = len(RE_MD_UNDER.findall(text))
    text = RE_MD_UNDER.sub(r"\1", text)
    n_bold = len(RE_MD_BOLD.findall(text))
    text = RE_MD_BOLD.sub("", text)
    return text, 2 * n_under + n_bold


def keep_reason(text: str) -> str | None:
    """整行注释块是否值得保留;返回命中的类别名,None = 删。"""
    if RE_TODO.search(text):
        return None
    if RE_DATE.search(text) and RE_HISTORY.search(text):
        return None
    if RE_SSOT.search(text):
        return "ssot"
    if RE_SILENT.search(text):
        return "silent"
    if RE_QUIRK.search(text):
        return "quirk"
    if RE_CONSQ.search(text) and RE_MUST.search(text):
        return "trap"
    return None


# ---------------------------------------------------------------- 清理


@dataclass
class Stat:
    path: str
    orig_lines: int = 0
    removed_lines: int = 0
    kept_lines: int = 0
    inline_removed: int = 0
    markdown_removed: int = 0
    kept_blocks: list[str] = field(default_factory=list)
    deleted_blocks: list[str] = field(default_factory=list)


def _trailing_blank_lines(lines: list[Line]) -> int:
    n = 0
    for ln in reversed(lines):
        if ln.text.strip():
            break
        n += 1
    return n


def strip_spans(text: str, spans: list[tuple[int, int]]) -> str:
    """删掉行内注释区间,两侧空白按"连同一个空格"处理。"""
    out = text
    for start, end in reversed(spans):
        before = out[:start]
        after = out[end:]
        b = before.rstrip(" \t")
        a = after.lstrip(" \t")
        if b.strip() and a.strip():
            out = b + " " + a
        elif b.strip():
            out = b
        elif a.strip():
            out = before + a
        else:
            out = b + a
    return out


def clean_text(text: str, path: str, strip_md: bool = False) -> tuple[str, Stat]:
    shader = path.endswith(".gdshader")
    lines = scan(text, shader)
    stat = Stat(path=path, orig_lines=len(lines))

    # 1) 行内注释:一律删
    for ln in lines:
        if ln.spans and ln.code().strip():
            stat.inline_removed += len(ln.spans)
            ln.text = strip_spans(ln.text, ln.spans)
            ln.spans = []

    # 2) 整行注释块:≤2 行且命中三类之一才留
    out: list[Line] = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.spans and not ln.code().strip():
            j = i
            while j < len(lines) and lines[j].spans and not lines[j].code().strip():
                j += 1
            block = lines[i:j]
            block_text = "\n".join(b.text.strip() for b in block)
            reason = keep_reason(block_text) if len(block) <= 2 else None
            if reason:
                stat.kept_lines += len(block)
                stat.kept_blocks.append(f"{block[0].text.strip()}  [{reason}]")
                if strip_md:
                    for b in block:
                        b.text, n = strip_markdown(b.text)
                        stat.markdown_removed += n
                out.extend(block)
            else:
                stat.removed_lines += len(block)
                stat.deleted_blocks.extend(b.text.strip() for b in block)
            i = j
            continue
        out.append(ln)
        i += 1

    new = "".join(ln.text + ln.eol for ln in out)

    # 保留原文件的末尾换行状态
    if text.endswith("\n") and not new.endswith("\n"):
        new += "\n" if not text.endswith("\r\n") else "\r\n"
    elif text and not text.endswith("\n") and new.endswith("\n"):
        new = new[:-1]

    # 删掉文件末尾的整段注释后,别在 EOF 留下新的空白行(原有空白行数量保持不变)
    orig_tail = _trailing_blank_lines(lines)
    out_tail = _trailing_blank_lines(out)
    if out_tail > orig_tail:
        del out[len(out) - (out_tail - orig_tail):]
        new = "".join(ln.text + ln.eol for ln in out)

    # 3) 兜底断言:代码签名不变
    old_sig = _code_signature(text, shader)
    new_sig = _code_signature(new, shader)
    if old_sig != new_sig:
        raise ScanError("清理后代码签名变化")
    return new, stat


def _code_signature(text: str, shader: bool) -> list[str]:
    sig = []
    for ln in scan(text, shader):
        code = ln.code().rstrip()
        if code.strip():
            sig.append(code)
    return sig


# ---------------------------------------------------------------- 遍历


def iter_files(root: Path) -> list[Path]:
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES)
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.suffix in SUFFIXES:
                found.append(p)
    return found


def _git(root: Path, *args: str) -> bytes:
    import subprocess

    proc = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True
    )
    if proc.returncode != 0:
        raise SystemExit(f"git 失败: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout


def git_tracked(root: Path) -> set[str]:
    out = _git(root, "ls-files", "-z", "--", "*.gd", "*.gdshader")
    return {x for x in out.decode("utf-8").split("\0") if x}


def git_dirty(root: Path) -> set[str]:
    """工作树里有改动(staged/unstaged)或未跟踪的受管文件。"""
    out = _git(root, "status", "--porcelain", "-z", "--untracked-files=all",
               "--", "*.gd", "*.gdshader")
    dirty = set()
    for chunk in out.decode("utf-8").split("\0"):
        if len(chunk) >= 4 and chunk[2] == " ":
            dirty.add(chunk[3:])
    return dirty


# ---------------------------------------------------------------- 自检


SELF_TESTS = [
    # (语言, 源码, 期望"行内注释数/整行注释数")
    ("gd", 'var a = 1 # c\n', (1, 0)),
    ("gd", 'var a = "x#y" # c\n', (1, 0)),
    ("gd", 'var a = "#"  # c\n', (1, 0)),
    ("gd", "var a = '#'  # c\n", (1, 0)),
    ("gd", 'var a = "#\n', None),
    ("gd", 'var a = """#\n// still string\n""" # c\n', (1, 0)),
    ("gd", "var a = '''#\n''' # c\n", (1, 0)),
    ("gd", 'var a = "x\ny#z" # c\n', (1, 0)),
    ("gd", "var a = 'x\ny#z' # c\n", (1, 0)),
    ("gd", 'var a = """x\\\ny#z""" # c\n', (1, 0)),
    ("gd", 'var a = "\\"#\\"" # c\n', (1, 0)),
    ("gd", 'var a = r"\\" # c\n', (1, 0)),
    ("gd", 'var a = &"#name" # c\n', (1, 0)),
    ("gd", 'var a = ^"#path" # c\n', (1, 0)),
    ("gd", "# full line\nvar a = 1\n", (0, 1)),
    ("gd", "## doc\nvar a = 1\n", (0, 1)),
    ("gd", "  # indented\n", (0, 1)),
    ("shader", "float a = 1.0; // c\n", (1, 0)),
    ("shader", '// c\n#include "res://x.gdshader"\n', (0, 1)),
    ("shader", 'x = "res://a"; // c\n', (1, 0)),
    ("shader", "/* a\nb */\nfloat c;\n", (0, 2)),
    ("shader", "float a = 1.0; /* c */\n", (1, 0)),
    ("shader", "float a = /* c */ 1.0;\n", (1, 0)),
    ("shader", "// a\n// b\n// c\n", (0, 3)),
]


CLEAN_TESTS = [
    ("a.gd", "var x = 1 # c\n", "var x = 1\n"),
    ("a.gd", 'var s = "#"  # c\n', 'var s = "#"\n'),
    ("a.gd", "# c\nvar x = 1\n", "var x = 1\n"),
    ("a.gd", "var x = 1 # c", "var x = 1"),
    ("a.gd", "var x = 1 # c\r\n", "var x = 1\r\n"),
    ("a.gd", "func a():\n\tpass\n\n# trailing\n", "func a():\n\tpass\n"),
    ("a.gd", "# 静默陷阱\nvar x = 1\n", "# 静默陷阱\nvar x = 1\n"),
    ("a.gd", "var s = \"x\ny#z\" # c\n", "var s = \"x\ny#z\"\n"),
    ("a.gdshader", "float a = 1.0; // c\n", "float a = 1.0;\n"),
    ("a.gdshader", "// c\nfloat a;\n", "float a;\n"),
]

CLEAN_MD_TESTS = [
    ("a.gd", "# **单一来源** 的 x\nvar a = 1\n", "# 单一来源 的 x\nvar a = 1\n"),
    ("a.gd", "# __粗体__ 静默\nvar a = 1\n", "# 粗体 静默\nvar a = 1\n"),
    ("a.gd", "# res://__l5__.gd 静默\nvar a = 1\n", "# res://__l5__.gd 静默\nvar a = 1\n"),
    ("a.gd", 'var s = "**x**" # **c**\n', 'var s = "**x**"\n'),
]


def self_test() -> int:
    bad = 0
    for lang, src, want in SELF_TESTS:
        shader = lang == "shader"
        try:
            lines = scan(src, shader)
        except ScanError:
            got = None
        else:
            got = (
                sum(1 for ln in lines if ln.spans and ln.code().strip()),
                sum(1 for ln in lines if ln.spans and not ln.code().strip()),
            )
        if got != want:
            bad += 1
            print(f"FAIL scan shader={shader} src={src!r} want={want} got={got}")
    for path, src, want in CLEAN_TESTS:
        try:
            got = clean_text(src, path)[0]
        except ScanError as exc:
            got = f"<{exc}>"
        if got != want:
            bad += 1
            print(f"FAIL clean path={path} src={src!r} want={want!r} got={got!r}")
    for path, src, want in CLEAN_MD_TESTS:
        try:
            got = clean_text(src, path, strip_md=True)[0]
        except ScanError as exc:
            got = f"<{exc}>"
        if got != want:
            bad += 1
            print(f"FAIL clean-md path={path} src={src!r} want={want!r} got={got!r}")
    print("SELF-TEST OK" if not bad else f"SELF-TEST FAIL ({bad})")
    return 0 if not bad else 1


# ---------------------------------------------------------------- 主流程


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="按 §10 清理仓库注释(默认干跑)")
    ap.add_argument("--write", action="store_true", help="落盘(默认只干跑)")
    ap.add_argument("--report", choices=["tsv"], help="stdout 输出每文件 TSV")
    ap.add_argument("--list", choices=["kept", "deleted"], help="列出将保留/将删的注释块")
    ap.add_argument("--limit", type=int, default=0, help="--list 输出上限(0=全部)")
    ap.add_argument("--root", type=Path, default=ROOT, help="仓库根(默认脚本上一级)")
    ap.add_argument("--only-tracked", action="store_true", help="只处理 git 已跟踪文件")
    ap.add_argument("--skip-dirty", action="store_true",
                    help="跳过工作树里有未提交改动(含暂存/未跟踪)的文件")
    ap.add_argument("--exclude", action="append", default=[],
                    help="额外跳过的仓库相对路径(可重复)")
    ap.add_argument("--files-from", type=Path,
                    help="只处理该文件里列出的仓库相对路径(每行一个)")
    ap.add_argument("--strip-markdown", action="store_true",
                    help="保留的注释里去掉 `**`/`__` 加粗标记(反引号按 §1 保留)")
    ap.add_argument("--self-test", action="store_true", help="跑扫描器夹具")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    root = args.root.resolve()
    files = iter_files(root)
    if args.only_tracked:
        tracked = git_tracked(root)
        files = [p for p in files if p.relative_to(root).as_posix() in tracked]
    if args.skip_dirty:
        dirty = git_dirty(root)
        files = [p for p in files if p.relative_to(root).as_posix() not in dirty]
    if args.exclude:
        skip = set(args.exclude)
        files = [p for p in files if p.relative_to(root).as_posix() not in skip]
    if args.files_from:
        wanted = {
            line.strip()
            for line in args.files_from.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        files = [p for p in files if p.relative_to(root).as_posix() in wanted]
    stats: list[Stat] = []
    errors: list[str] = []
    changed = 0
    for p in files:
        rel = p.relative_to(root).as_posix()
        try:
            raw = p.read_bytes().decode("utf-8")
            new, stat = clean_text(raw, rel, args.strip_markdown)
            if clean_text(new, rel, args.strip_markdown)[0] != new:
                raise ScanError("清理结果不幂等")
        except (UnicodeDecodeError, ScanError) as exc:
            errors.append(f"{rel}: {exc}")
            continue
        stats.append(stat)
        if new != raw:
            changed += 1
            if args.write:
                p.write_bytes(new.encode("utf-8"))

    if args.report == "tsv":
        print("file\torig_lines\tdeleted_comment_lines\tkept_lines\tkept_comment_lines\tinline_comments_removed")
        for st in stats:
            final_lines = st.orig_lines - st.removed_lines
            print(
                f"{st.path}\t{st.orig_lines}\t{st.removed_lines}\t{final_lines}\t"
                f"{st.kept_lines}\t{st.inline_removed}"
            )
    elif args.list:
        for st in stats:
            for sample in st.kept_blocks if args.list == "kept" else st.deleted_blocks:
                print(f"{st.path}: {sample}")
                if args.limit and args.limit > 0:
                    args.limit -= 1
                    if args.limit == 0:
                        return 0
    else:
        _print_summary(stats, errors, changed, args.write)
    return 1 if errors else 0


def _print_summary(stats: list[Stat], errors: list[str], changed: int, wrote: bool) -> None:
    scanned = len(stats)
    orig = sum(s.orig_lines for s in stats)
    removed = sum(s.removed_lines for s in stats)
    kept = sum(s.kept_lines for s in stats)
    inline = sum(s.inline_removed for s in stats)
    md = sum(s.markdown_removed for s in stats)
    blocks = sum(len(s.kept_blocks) for s in stats)
    mode = "WROTE" if wrote else "DRY-RUN"
    print(f"[{mode}] 文件 {scanned} · 行 {orig}")
    print(f"  整行注释: 删 {removed} 行 / 留 {kept} 行({blocks} 块,均 ≤2 行)")
    print(f"  行内注释: 删 {inline} 处")
    if md:
        print(f"  Markdown 加粗标记: 删 {md} 个")
    print(f"  将变更文件: {changed} / {scanned}")
    if errors:
        print(f"  跳过(扫描失败) {len(errors)}:")
        for e in errors:
            print(f"    {e}")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())


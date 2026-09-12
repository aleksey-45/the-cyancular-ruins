#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""notes_organizer -- turn the free-form inbox docs/Temp.txt into rows of DevelopHistoryAndPlan.xlsx.

Inbox format (all markers optional; the parser is forgiving):

    v1.1.4企划部分:                  <- section line: sets 目标版本 (vX.Y.Z). No version line -> 未定/企划池
    RoF负责:                         <- owner line: sets 负责人. Trailing (bracketed) text becomes 关联/备注
    1. move the royale server ...    <- item lines: start with 1. / - / * ; an unmarked line continues the previous item
    2. unify the UI style ...

    KikuchiH负责:(may land in v1.1.5)
    1. fix every UI overlap

Routing rules:
  * every item becomes one row of the 计划与企划 sheet, columns
      来源 | 目标版本 | 负责人 | 状态 | 条目 | 关联 / 备注
  * 来源 = 下一版计划 when a concrete vX.Y.Z was given, otherwise 企划池
  * 状态 defaults to 待办; 关联 / 备注 carries the owner-level note
  * identical item text is skipped, so clicking twice is harmless
  * the raw inbox text is archived to docs/notes_archive/ and Temp.txt is emptied

Everything this tool creates uses English names (file names, identifiers, CLI verbs,
state dirs) to stay clear of codepage/path trouble; the workbook *content* stays Chinese.

Entry points
------------
  tools/notes_organizer.cmd   double-click on Windows; runs this .py directly, so edits take effect at once
  tools/NotesOrganizer.exe    PyInstaller onefile build; must stay in tools/ (repo root = its grandparent)
  python tools/notes_organizer.py [--dry-run] [--keep-inbox] [--workbook PATH] [--inbox PATH]

Rebuild the exe after editing this file (the exe is a snapshot and will go stale otherwise):
  python -m PyInstaller --onefile --console --name NotesOrganizer tools/notes_organizer.py
"""
import argparse, datetime, io, json, math, os, re, shutil, sys, unicodedata

REPO = os.path.dirname(os.path.dirname(os.path.abspath(
    sys.executable if getattr(sys, "frozen", False) else __file__)))
# Packed with PyInstaller --onefile, __file__ points into the temp unpack dir, so anchor on the
# executable instead: keep the exe inside tools/ and the repo root resolves to its grandparent.
INBOX = os.path.join(REPO, "docs", "Temp.txt")
WORKBOOK = os.path.join(REPO, "docs", "DevelopHistoryAndPlan.xlsx")
ARCHIVE_DIR = os.path.join(REPO, "docs", "notes_archive")
SHEET_PLAN = "计划与企划"
SHEET_GUIDE = "维护说明"

HEADERS = ["来源", "目标版本", "负责人", "状态", "条目", "关联 / 备注"]
COL_WIDTHS = {"B": 13, "C": 11, "D": 12, "E": 10, "F": 54, "G": 34}
STATUS_CHOICES = ["待办", "进行中", "已完成"]
GUIDE_BLOCK = "Temp.txt 规则"

VERSION_RE = re.compile(r"^\s*(v\d+(?:\.\d+)*)\s*(.*)$")
OWNER_RE = re.compile(r"^\s*(.+?)\s*负责\s*[:：]?\s*(.*)$")
ITEM_RE = re.compile(r"^\s*(?:\d+\s*[.、)）]|[-*•·])\s*(.+?)\s*$")
BRACKET_RE = re.compile(r"^[（(]\s*(.+?)\s*[）)]\s*$")


# ---------------------------------------------------------------- helpers
def dwidth(text):
    """Rough display width: CJK counts 1.7, others 1."""
    return sum(1.7 if unicodedata.east_asian_width(c) in "WF" else 1 for c in str(text or ""))


def lines_needed(text, col_width):
    return max(1, math.ceil(dwidth(text) / max(1.0, col_width * 0.9)))


def row_height(text, col_width, base=22.0, per_line=16.0):
    return max(base, base + (lines_needed(text, col_width) - 1) * per_line)


def key_of(text):
    """Dedupe key: collapse whitespace and punctuation width so trivial rewrites still match."""
    s = re.sub(r"\s+", "", str(text or ""))
    return s.replace("，", ",").replace("：", ":").replace("；", ";").replace("（", "(").replace("）", ")")


def log(msg):
    print(msg)


# ---------------------------------------------------------------- parse inbox
def parse_inbox(text):
    """Return [ {source, version, owner, note, text} ], skipping blanks and unmarked prose."""
    items = []
    version, owner, note = "", "", ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        m = VERSION_RE.match(line)
        # A version line must not be an item line ("1. xxx" starts with a digit, not 'v')
        if m:
            version, rest = m.group(1), m.group(2).strip(" :：")
            owner, note = "", ""
            continue
        m = OWNER_RE.match(line)
        if m:
            owner = m.group(1).strip()
            tail = m.group(2).strip()
            b = BRACKET_RE.match(tail)
            note = b.group(1) if b else tail
            continue
        m = ITEM_RE.match(line)
        if m:
            items.append({"source": "下一版计划" if version else "企划池",
                          "version": version or "未定", "owner": owner,
                          "note": note, "text": m.group(1)})
            continue
        if items:
            # unmarked line -> continuation of the previous item
            items[-1]["text"] += line.strip()
        else:
            items.append({"source": "下一版计划" if version else "企划池",
                          "version": version or "未定", "owner": owner,
                          "note": note, "text": line.strip()})
    return items


# ---------------------------------------------------------------- plan sheet IO
def read_plan_rows(ws):
    """Existing rows as records (old layout has no 负责人 column -> filled with '')."""
    headers = [ws.cell(row=4, column=c).value for c in range(2, ws.max_column + 1)]
    out = []
    for r in range(5, ws.max_row + 1):
        vals = [ws.cell(row=r, column=c).value for c in range(2, ws.max_column + 1)]
        if not any(v not in (None, "") for v in vals):
            continue
        rec = {"source": "", "version": "未定", "owner": "", "status": "待办", "text": "", "note": ""}
        for h, v in zip(headers, vals):
            h = str(h or "").replace(" ", "")
            if h == "来源":
                rec["source"] = v or ""
            elif h == "目标版本":
                rec["version"] = v or "未定"
            elif h == "负责人":
                rec["owner"] = v or ""
            elif h == "状态":
                rec["status"] = v or "待办"
            elif h == "条目":
                rec["text"] = v or ""
            elif h in ("关联/备注", "备注"):
                rec["note"] = v or ""
        if rec["text"]:
            out.append(rec)
    return out


def merge_rows(existing, incoming):
    """Append new items, skipping duplicates. Returns (merged, added, skipped)."""
    seen = {key_of(r["text"]) for r in existing}
    merged = list(existing)
    added, skipped = [], []
    for it in incoming:
        k = key_of(it["text"])
        if not k or k in seen:
            skipped.append(it)
            continue
        seen.add(k)
        rec = {"source": it["source"], "version": it["version"], "owner": it["owner"],
               "status": "待办", "text": it["text"], "note": it["note"]}
        merged.append(rec)
        added.append(rec)
    # stable sort: 下一版计划 first, then version, then owner (first-appearance order preserved)
    owner_rank = {}
    for r in merged:
        owner_rank.setdefault(r["owner"], len(owner_rank))
    merged.sort(key=lambda r: (0 if r["source"] == "下一版计划" else 1,
                               str(r["version"]), owner_rank.get(r["owner"], 999)))
    return merged, added, skipped


def style_snapshot(ws):
    """Copy the visual style of the existing sheet so rebuilt rows look identical."""
    from copy import copy
    snap = {"title": {}, "header": {}, "data": []}
    for attr in ("font", "fill", "border", "alignment"):
        snap["title"][attr] = copy(getattr(ws.cell(row=2, column=2), attr))
        snap["header"][attr] = copy(getattr(ws.cell(row=4, column=2), attr))
    for r in (5, 6):                       # the two alternating data-row variants
        snap["data"].append({a: copy(getattr(ws.cell(row=r, column=2), a))
                             for a in ("font", "fill", "border", "alignment")})
    return snap


def apply_style(cell, style):
    from copy import copy
    cell.font = copy(style["font"])
    cell.fill = copy(style["fill"])
    cell.border = copy(style["border"])
    cell.alignment = copy(style["alignment"])


def rebuild_plan_sheet(wb, stale, rows, snap):
    """Replace the plan sheet with a freshly laid out one (same look, extra 负责人 column)."""
    from openpyxl.utils import get_column_letter
    from openpyxl.styles import Alignment
    from openpyxl.worksheet.datavalidation import DataValidation
    from openpyxl.formatting.rule import CellIsRule
    from openpyxl.styles import PatternFill, Font

    idx = wb.sheetnames.index(SHEET_PLAN)
    wb.remove(stale)
    ws = wb.create_sheet(SHEET_PLAN, idx)
    last_col = len(HEADERS) + 1                      # B..G
    last_letter = get_column_letter(last_col)

    ws.sheet_view.showGridLines = False
    ws.column_dimensions["A"].width = 3
    for col, w in COL_WIDTHS.items():
        ws.column_dimensions[col].width = w
    ws.row_dimensions[1].height = 15
    ws.row_dimensions[2].height = 32
    ws.row_dimensions[3].height = 8

    ws.merge_cells(start_row=2, start_column=2, end_row=2, end_column=last_col)
    t = ws.cell(row=2, column=2, value="The Cyancular Ruins · 开发记录 · 计划与企划")
    apply_style(t, snap["title"])

    for i, h in enumerate(HEADERS, start=2):
        c = ws.cell(row=4, column=i, value=h)
        apply_style(c, snap["header"])
    ws.row_dimensions[4].height = 28

    for i, rec in enumerate(rows):
        r = 5 + i
        for j, val in enumerate([rec["source"], rec["version"], rec["owner"],
                                 rec["status"], rec["text"], rec["note"]], start=2):
            ws.cell(row=r, column=j, value=val if val != "" else None)
        variant = snap["data"][i % 2]
        for j in range(2, last_col + 1):
            cell = ws.cell(row=r, column=j)
            apply_style(cell, variant)
            if j == 4:                               # 状态: center it
                cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        ws.row_dimensions[r].height = max(
            row_height(rec["text"], COL_WIDTHS["F"]),
            row_height(rec["note"], COL_WIDTHS["G"]))

    end = 4 + len(rows)
    ws.freeze_panes = "C5"
    ws.auto_filter.ref = "B4:%s%d" % (last_letter, end)

    if rows:
        dv = DataValidation(type="list", formula1='"%s"' % ",".join(STATUS_CHOICES),
                            allow_blank=True, showDropDown=False)
        ws.add_data_validation(dv)
        dv.add("E5:E%d" % end)
        for text, bg, fg in (("已完成", "E8F5E9", "1B7D46"), ("进行中", "FEF9E7", "D4820A")):
            ws.conditional_formatting.add(
                "E5:E%d" % end,
                CellIsRule(operator="equal", formula=['"%s"' % text],
                           fill=PatternFill(start_color=bg, end_color=bg, fill_type="solid"),
                           font=Font(name="Noto Sans SC", color=fg)))
    return ws


def ensure_guide(ws, inbox_name, script_name):
    """Append the inbox-format rules to the guide sheet (idempotent)."""
    from openpyxl.utils import get_column_letter
    last = 4
    for r in range(5, ws.max_row + 1):
        if ws.cell(row=r, column=2).value not in (None, ""):
            last = r
    if any(ws.cell(row=r, column=2).value == GUIDE_BLOCK for r in range(5, last + 1)):
        return 0
    rows = [
        ("章节行", "版本行(如 `v1.1.4企划部分:`)-> 决定「目标版本」;整份没有版本行则记 未定 / 企划池。"),
        ("负责人行", "`RoF负责:` -> 决定「负责人」;行尾括号内文字会记进「关联 / 备注」。"),
        ("条目行", "`1.` / `-` / `*` 开头各成一条;不带头标记的续行并入上一条。"),
        ("入库方式", "运行 tools/%s:条目写进「计划与企划」,重复条目自动跳过,原文存 docs/notes_archive/ 后清空 %s。"
                     % (script_name, inbox_name)),
    ]
    from copy import copy
    variants = [{a: copy(getattr(ws.cell(row=r, column=2), a))
                 for a in ("font", "fill", "border", "alignment")} for r in (5, 6)]
    for i, (item, desc) in enumerate(rows):
        r = last + 1 + i
        ws.cell(row=r, column=2, value=GUIDE_BLOCK)
        ws.cell(row=r, column=3, value=item)
        ws.cell(row=r, column=4, value=desc)
        for j in range(2, 5):
            apply_style(ws.cell(row=r, column=j), variants[i % 2])
        ws.row_dimensions[r].height = row_height(desc, 66)
    ws.auto_filter.ref = "B4:D%d" % (last + len(rows))
    return len(rows)


# ---------------------------------------------------------------- main flow
def organize(args):
    inbox = args.inbox or INBOX
    wb_path = args.workbook or WORKBOOK
    if not os.path.isfile(inbox):
        log("找不到收件箱: %s" % inbox)
        return 1
    text = io.open(inbox, encoding="utf-8", errors="replace").read()
    items = parse_inbox(text)
    if not items:
        log("收件箱里没解析出任何条目(空文件,或只有不成条的说明文字)。")
        log("格式示例:")
        log("    v1.1.4企划部分:")
        log("    RoF负责:")
        log("    1. 把大乱斗服务器迁移到公共服务器")
        return 1

    from openpyxl import load_workbook
    wb = load_workbook(wb_path)
    if SHEET_PLAN not in wb.sheetnames:
        log("工作簿里没有「%s」页。" % SHEET_PLAN)
        return 1
    stale = wb[SHEET_PLAN]
    snap = style_snapshot(stale)
    existing = read_plan_rows(stale)
    merged, added, skipped = merge_rows(existing, items)

    log("解析出 %d 条,新增 %d 条,跳过重复 %d 条。" % (len(items), len(added), len(skipped)))
    for s in skipped:
        log("  跳过(已存在): %s" % s["text"][:40])
    if args.dry_run:
        log("--dry-run: 不改动任何文件。将新增:")
        for a in added:
            log("  [%s/%s/%s] %s" % (a["source"], a["version"], a["owner"] or "-", a["text"]))
        return 0

    rebuild_plan_sheet(wb, stale, merged, snap)
    if SHEET_GUIDE in wb.sheetnames:
        added_guide = ensure_guide(wb[SHEET_GUIDE], os.path.basename(inbox),
                                   os.path.basename(__file__))
        if added_guide:
            log("「%s」页补了 %d 行收件箱格式说明。" % (SHEET_GUIDE, added_guide))
    wb.save(wb_path)

    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    arch = os.path.join(ARCHIVE_DIR, "%s_inbox.txt" % stamp)
    shutil.copy2(inbox, arch)
    log("原文已归档: %s" % arch)
    if not args.keep_inbox:
        io.open(inbox, "w", encoding="utf-8").write("")
        log("收件箱已清空,可以写下一批想法了。")
    log("已写入 %s(计划与企划共 %d 行)。" % (os.path.basename(wb_path), len(merged)))
    return 0


def pause_if_interactive():
    """Waiting here (instead of the launcher's `pause`) keeps every message in one encoding:
    cmd's own pause prompt is localized in the console codepage and would garble mixed output."""
    try:
        if sys.stdin and sys.stdin.isatty():
            print()
            input("按回车键关闭…")
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser(description="把 docs/Temp.txt 的想法整理进 DevelopHistoryAndPlan.xlsx")
    ap.add_argument("command", nargs="?", default="organize", choices=["organize"])
    ap.add_argument("--dry-run", action="store_true", help="只演示会新增什么,不改文件")
    ap.add_argument("--keep-inbox", action="store_true", help="整理后不清空 Temp.txt")
    ap.add_argument("--workbook", help="覆盖目标工作簿(默认 docs/DevelopHistoryAndPlan.xlsx)")
    ap.add_argument("--inbox", help="覆盖收件箱(默认 docs/Temp.txt)")
    args = ap.parse_args()
    rc = organize(args)
    pause_if_interactive()
    return rc


if __name__ == "__main__":
    sys.exit(main())

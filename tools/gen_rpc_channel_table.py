#!/usr/bin/env python3
# RPC 通道表 ↔ 代码声明的对账 / 生成工具(单一真相源入口)。
#
# 为什么需要它:`docs/eng/netplay-rpc-channels.md` 那张通道表是**手抄 markdown**,刷新靠人眼。
# 历史上已经漂过:DD-01 记录「代码 61 条 / 文档 60 条,通道 3 漏 explosion」;而 2026-10-24 的
# 默认批削减把唯一一条文本对账 -s 守卫(`rpc_channel_contract_smoke`)删掉后,漂移彻底没人报了。
# 本工具按同款口径(`level_editor/sync-enemies.js --check` / `tools/gen_menu_theme.gd`:只校验不写盘、
# 漂移退 1)把「文档表 ↔ 两个 autoload 的 @rpc 声明」变成生成式对账。
#
# 用法:
#   python tools/gen_rpc_channel_table.py --check     # 对账;漂移逐项打印 + exit 1,一致打印 OK + exit 0
#   python tools/gen_rpc_channel_table.py --write     # 按代码幂等重写文档的「RPC 列 / 合计数字 / 作用域数字」
#   python tools/gen_rpc_channel_table.py --self-test # 解析/对账纯函数的自测(合成文本,不写盘)
#
# ★ 扫描口径(改之前先读 docs/eng/netplay-rpc-channels.md 的「声明与对账」):
#   - 只认**行首** `@rpc(`:注释里的 @rpc 不算;缩进的 @rpc 会被**点名报错**(否则会被静默漏计);
#   - 通道号 = 四个参数里最后那个 int;要求四参全写(三参把 int 放第 3 位引擎会拒,文本上看不出);
#   - `@rpc` 行与 `func 名(` 行之间允许空行;中间夹别的行就红(认不出不猜)。
#
# ★ 最强保证 = 「两个 autoload 的声明文本 ↔ 文档表/合计行」逐项一致,且同一 RPC 名不跨两个 autoload。
# ★ 测不到(照实登记):
#   1. 运行期派发 —— 通道号在 `GDScript.get_script_method_list()` 里回读不到,本工具零引擎依赖;
#   2. `@rpc` 行是否真被引擎接受(格式对 ≠ 引擎认;那要拉引擎跑);
#   3. 发送端/接收端挂的是哪个节点(只有代码注释与「重名集合」间接约束)。
import os
import re
import sys
from collections import Counter

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
NET_FILES = ("core/net/net_bus.gd", "core/net/net_bus_ext.gd")
DOC = "docs/eng/netplay-rpc-channels.md"
TABLE_CHANNELS = (0, 1, 2, 3)

_RPC_LINE = re.compile(r"^@rpc\s*\((.*)\)\s*(?:#.*)?$")
_INDENTED_RPC = re.compile(r"^[ \t]+@rpc\s*\(")
_FUNC_LINE = re.compile(r"^func\s+([A-Za-z_]\w*)\s*\(")
_STR_ARG = re.compile(r'^"[^"]*"$')
_INT_ARG = re.compile(r"^\d+$")

_ROW_RE = re.compile(r"^\|\s*\*\*(\d+)\*\*([^|]*)\|(.*)\|\s*$")
_NAME_TOKEN = re.compile(r"`([a-z][a-z0-9_]*)`")
_TOTAL_RE = re.compile(r"合计\s*(\d+)\s*条")
_PER_CH_RE = re.compile(r"0\s*=\s*(\d+)\s*/\s*1\s*=\s*(\d+)\s*/\s*2\s*=\s*(\d+)\s*/\s*3\s*=\s*(\d+)")
_SCOPE_RE = re.compile(r"产品声明\s*\*\*(\d+)\*\*\s*条\s*[\(（]\s*`net_bus\.gd`\s*(\d+)\s*\+\s*"
                       r"`net_bus_ext\.gd`\s*(\d+)\s*[\)）]")
_SCOPE_CH_RE = re.compile(r"0/1/2/3\s*=\s*(\d+)/(\d+)/(\d+)/(\d+)")
_NAMES_RE = re.compile(r"表里\s*\*\*(\d+)\*\*\s*个方法名")
_DECLS_RE = re.compile(r"=\s*\*\*(\d+)\*\*\s*条声明")


def parse_decls(text: str, rel: str):
    """从一份 `.gd` 文本里抽出行首 `@rpc(...)` + 紧随的 `func 名(`。返回 (decls, problems)。

    decls = [{"file", "line", "name", "channel"}]。纯函数:便于 `--self-test` 喂合成文本。
    """
    lines = text.splitlines()
    decls, problems = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        if _INDENTED_RPC.match(line):
            problems.append("%s:%d 缩进的 `@rpc(` 声明(本工具只认行首;顶格写,否则会被静默漏计)"
                            % (rel, i + 1))
            i += 1
            continue
        m = _RPC_LINE.match(line)
        if not m:
            i += 1
            continue
        args = [a.strip() for a in m.group(1).split(",")]
        bad = []
        if len(args) != 4:
            bad.append("参数 %d 个(要 4 个:mode/sync/transfer_mode/transfer_channel)" % len(args))
        else:
            if not all(_STR_ARG.match(a) for a in args[:3]):
                bad.append("前 3 个参数必须是字符串,实为 %r" % (", ".join(args[:3]),))
            if not _INT_ARG.match(args[3]):
                bad.append("第 4 个参数 transfer_channel 必须是纯整数,实为 %r" % args[3])
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        fm = _FUNC_LINE.match(lines[j]) if j < len(lines) else None
        if fm is None:
            where = "文件结束" if j >= len(lines) else "第 %d 行 %r" % (j + 1, lines[j].strip()[:60])
            bad.append("后面不是行首 `func 名(`(中间只允许空行;实际 %s)" % where)
        if bad:
            problems.append("%s:%d `@rpc` 声明不合规: %s" % (rel, i + 1, ";".join(bad)))
        else:
            decls.append({"file": rel, "line": i + 1, "name": fm.group(1),
                          "channel": int(args[3])})
        i += 1
    return decls, problems


def duplicate_problems(decls):
    """同一 RPC 名不得同时出现在两个 autoload(挂错节点 = 静默 no-op)。"""
    files_by_name = {}
    for d in decls:
        files_by_name.setdefault(d["name"], set()).add(d["file"])
    probs = []
    for name in sorted(files_by_name):
        files = files_by_name[name]
        if len(files) > 1:
            probs.append("同一 RPC 名同时出现在 %s: `%s`(接收端挂错节点 = 静默 no-op)"
                         % (" 与 ".join(sorted(files)), name))
    return probs


def generated_summary(decls):
    """代码侧事实:总条数、每文件条数、每通道条数、每通道名单、唯一名数。"""
    per_file = Counter(d["file"] for d in decls)
    ch = Counter(d["channel"] for d in decls)
    return {
        "total": len(decls),
        "unique": len({d["name"] for d in decls}),
        "per_file": per_file,
        "channels": {c: ch.get(c, 0) for c in TABLE_CHANNELS},
        "extra_channels": {c: n for c, n in sorted(ch.items()) if c not in TABLE_CHANNELS},
        "names_by_channel": {c: Counter(d["name"] for d in decls if d["channel"] == c)
                             for c in TABLE_CHANNELS},
    }


def parse_doc(text: str):
    """从文档文本里抽出通道表四行 + 三类数字行。字段缺失留 None/``-1``,由 `check()` 点名。

    表格行只认 `| **N** … |`(即通道号单元格),`parse_doc` 不猜别的 markdown 形态。
    """
    d = {"rows": {}, "problems": [], "total": None, "total_line": -1,
         "per_channel": None, "scope": None, "scope_line": -1,
         "names": None, "names_line": -1}
    for idx, line in enumerate(text.splitlines()):
        m = _ROW_RE.match(line)
        if m:
            ch = int(m.group(1))
            if ch in d["rows"]:
                d["problems"].append("通道表里通道 %d 出现了两行" % ch)
                continue
            cells = [c.strip() for c in m.group(3).split("|")]
            if len(cells) != 3:
                d["problems"].append("通道 %d 行的表格列数不对(表应有 4 列:通道/ENet 道/语义/RPC)"
                                     % ch)
            channel_cell = "**%d**%s" % (ch, m.group(2).strip())
            d["rows"][ch] = {"line": idx + 1, "channel_cell": channel_cell, "cells": cells}
            continue
        tm = _TOTAL_RE.search(line)
        if tm and d["total"] is None:
            d["total"] = int(tm.group(1))
            d["total_line"] = idx
            pc = _PER_CH_RE.search(line)
            if pc:
                d["per_channel"] = [int(x) for x in pc.groups()]
        sm = _SCOPE_RE.search(line)
        if sm and d["scope"] is None:
            chm = _SCOPE_CH_RE.search(line)
            d["scope"] = {"total": int(sm.group(1)),
                          "files": (int(sm.group(2)), int(sm.group(3))),
                          "channels": [int(x) for x in chm.groups()] if chm else None}
            d["scope_line"] = idx
        nm = _NAMES_RE.search(line)
        if nm and d["names"] is None:
            dm = _DECLS_RE.search(line)
            d["names"] = {"names": int(nm.group(1)),
                          "decls": int(dm.group(1)) if dm else None}
            d["names_line"] = idx
    return d


def doc_names(doc):
    """文档表每行的 RPC 名单(多重集:同名重复出现也保留,便于和声明条数一一对上)。"""
    out = {}
    for ch, info in doc["rows"].items():
        out[ch] = Counter(_NAME_TOKEN.findall(info["cells"][-1]))
    return out


def check(decls, doc_text, code_problems=()):
    """对账。返回 (diffs, doc, gen):diffs 为空 = 一致。`--check` 与 `--write` 共用这一套判据。"""
    gen = generated_summary(decls)
    diffs = list(code_problems) + duplicate_problems(decls)
    if not decls:
        diffs.append("一个 @rpc 声明都没扫到 —— 两个 autoload 的路径或扫描口径坏了?")
    if gen["extra_channels"]:
        diffs.append("代码出现表外通道 %s 的声明 —— 本表只列 0~3(先决定这些 RPC 归哪条道)"
                     % ", ".join("%d(%d 条)" % (c, n) for c, n in gen["extra_channels"].items()))
    doc = parse_doc(doc_text)
    diffs.extend(doc["problems"])

    # ① 每通道名单:代码声明(多重集) ↔ 表里该行的 RPC 列
    for ch in TABLE_CHANNELS:
        if ch not in doc["rows"]:
            diffs.append("通道表缺少通道 %d 的行(表头/表被改坏?)" % ch)
            continue
        got, want = doc_names(doc).get(ch, Counter()), gen["names_by_channel"][ch]
        if got != want:
            miss, extra = want - got, got - want
            if miss:
                diffs.append("通道 %d 名单缺少(代码有、表里没有): %s"
                             % (ch, ", ".join(sorted(miss.elements()))))
            if extra:
                diffs.append("通道 %d 名单多出(表里有、代码没有): %s"
                             % (ch, ", ".join(sorted(extra.elements()))))
    for ch in sorted(doc["rows"]):
        if ch not in TABLE_CHANNELS:
            diffs.append("通道表出现非预期通道 %d(本表只列 0~3)" % ch)

    # ② 合计行:`**合计 N 条**` + `0 = a / 1 = b / 2 = c / 3 = d`
    if doc["total"] is None:
        diffs.append("找不到「合计 N 条」行")
    elif doc["total"] != gen["total"]:
        diffs.append("合计条数: 文档 %d / 代码 %d" % (doc["total"], gen["total"]))
    if doc["per_channel"] is None:
        diffs.append("找不到合计行里的「0 = a / 1 = b / 2 = c / 3 = d」每通道条数")
    else:
        for i, ch in enumerate(TABLE_CHANNELS):
            if doc["per_channel"][i] != gen["channels"][ch]:
                diffs.append("通道 %d 条数: 文档 %d / 代码 %d"
                             % (ch, doc["per_channel"][i], gen["channels"][ch]))

    # ③ 作用域行:产品声明总数 + 每文件条数 + 每通道条数
    if doc["scope"] is None:
        diffs.append("找不到「作用域:产品声明 **N** 条(`net_bus.gd` a + "
                     "`net_bus_ext.gd` b);… 0/1/2/3 = …」行")
    else:
        sc = doc["scope"]
        if sc["total"] != gen["total"]:
            diffs.append("作用域声明总数: 文档 %d / 代码 %d" % (sc["total"], gen["total"]))
        want_files = (gen["per_file"].get(NET_FILES[0], 0), gen["per_file"].get(NET_FILES[1], 0))
        if sc["files"] != want_files:
            diffs.append("作用域每文件条数: 文档 net_bus=%d + net_bus_ext=%d / 代码 %d + %d"
                         % (sc["files"][0], sc["files"][1], want_files[0], want_files[1]))
        if sc["channels"] is None:
            diffs.append("作用域行里找不到「0/1/2/3 = a/b/c/d」")
        else:
            for i, ch in enumerate(TABLE_CHANNELS):
                if sc["channels"][i] != gen["channels"][ch]:
                    diffs.append("作用域每通道条数 0/1/2/3: 文档 %s / 代码 %s"
                                 % (sc["channels"], [gen["channels"][c] for c in TABLE_CHANNELS]))

    # ④ 「表里 N 个方法名 = M 条声明」:N 必须是去重后的方法名数,M 是声明条数
    if doc["names"] is None:
        diffs.append("找不到「表里 **N** 个方法名 = **M** 条声明」行")
    else:
        if doc["names"]["names"] != gen["unique"]:
            diffs.append("「表里 N 个方法名」: 文档 %d / 代码唯一方法名 %d"
                         % (doc["names"]["names"], gen["unique"]))
        if doc["names"]["decls"] is None:
            diffs.append("「= **M** 条声明」的 M 找不到")
        elif doc["names"]["decls"] != gen["total"]:
            diffs.append("「表里 … = M 条声明」: 文档 %d / 代码声明 %d"
                         % (doc["names"]["decls"], gen["total"]))
    return diffs, doc, gen


def _cell_suffix(cell: str) -> str:
    """保留 RPC 名单后面的说明文字(通道 1 的「(60Hz …)」);名单本身由代码生成。"""
    rest = []
    for chunk in cell.split(" / "):
        r = _NAME_TOKEN.sub("", chunk.strip()).strip()
        if r:
            rest.append(r)
    return " / ".join(rest)


def write_doc(decls, doc_text, code_problems=()):
    """按代码重写文档的 RPC 列与三类数字行。返回 (new_text, changes);无需改动时 new_text=None。

    只改**机器可推导**的那几处(表最后一列 / 合计行 / 作用域行 / 表里方法名行),语义文字原样保留。
    结构缺失或代码侧本身不合规时抛 ``ValueError``(不在文档里掩盖代码问题)。
    """
    _, doc, gen = check(decls, doc_text, code_problems)
    if code_problems or duplicate_problems(decls):
        raise ValueError("代码侧声明不合规(见 --check 输出),拒绝按它改写文档")
    if gen["extra_channels"]:
        raise ValueError("代码出现表外通道 0~3 的声明,本表无对应行可写")
    if set(doc["rows"]) != set(TABLE_CHANNELS):
        raise ValueError("通道表骨架不是 0~3 四行,拒绝 --write(先手工修表)")
    if any(len(doc["rows"][c]["cells"]) != 3 for c in TABLE_CHANNELS):
        raise ValueError("通道表某行不是 4 列,拒绝 --write(先手工修表)")

    lines = doc_text.splitlines()
    changes = 0
    for ch in TABLE_CHANNELS:
        info = doc["rows"][ch]
        cells = list(info["cells"])
        names = sorted(d["name"] for d in decls if d["channel"] == ch)
        new_cell = " / ".join("`%s`" % n for n in names) + _cell_suffix(cells[-1])
        if cells[-1] != new_cell:
            cells[-1] = new_cell
            lines[info["line"] - 1] = "| %s | %s |" % (info["channel_cell"], " | ".join(cells))
            changes += 1

    def rewrite(idx, subs, missing):
        nonlocal changes
        if idx < 0:
            raise ValueError(missing)
        old = lines[idx]
        new = old
        for pat, rep in subs:
            new = re.sub(pat, rep, new)
        if new != old:
            lines[idx] = new
            changes += 1

    rewrite(doc["total_line"], [
        (r"合计\s*\d+\s*条", "合计 %d 条" % gen["total"]),
        (r"0\s*=\s*\d+\s*/\s*1\s*=\s*\d+\s*/\s*2\s*=\s*\d+\s*/\s*3\s*=\s*\d+",
         "0 = %d / 1 = %d / 2 = %d / 3 = %d" % tuple(gen["channels"][c] for c in TABLE_CHANNELS)),
    ], "找不到合计行,拒绝 --write")
    rewrite(doc["scope_line"], [
        (r"产品声明\s*\*\*\d+\*\*\s*条", "产品声明 **%d** 条" % gen["total"]),
        (r"`net_bus\.gd`\s*\d+", "`net_bus.gd` %d" % gen["per_file"].get(NET_FILES[0], 0)),
        (r"`net_bus_ext\.gd`\s*\d+", "`net_bus_ext.gd` %d" % gen["per_file"].get(NET_FILES[1], 0)),
        (r"0/1/2/3\s*=\s*\d+/\d+/\d+/\d+",
         "0/1/2/3 = %d/%d/%d/%d" % tuple(gen["channels"][c] for c in TABLE_CHANNELS)),
    ], "找不到作用域行,拒绝 --write")
    rewrite(doc["names_line"], [
        (r"表里\s*\*\*\d+\*\*\s*个方法名", "表里 **%d** 个方法名" % gen["unique"]),
        (r"=\s*\*\*\d+\*\*\s*条声明", "= **%d** 条声明" % gen["total"]),
    ], "找不到「表里 N 个方法名」行,拒绝 --write")

    if changes == 0:
        return None, 0
    new_text = "\n".join(lines) + ("\n" if doc_text.endswith("\n") else "")
    after, _, _ = check(decls, new_text, code_problems)   # 写盘前自检:重写后必须一致
    if after:
        raise ValueError("重写后仍有漂移(工具自身的 bug,未写盘): " + "; ".join(after))
    return new_text, changes


def load_inputs():
    """读两个 autoload 与文档。返回 (decls, doc_text, problems)。"""
    problems, decls = [], []
    for rel in NET_FILES:
        full = os.path.join(PROJECT, rel)
        if not os.path.exists(full):
            problems.append("找不到源码: %s" % rel)
            continue
        with open(full, encoding="utf-8", errors="replace") as fh:
            ds, ps = parse_decls(fh.read(), rel)
        decls.extend(ds)
        problems.extend(ps)
    doc_full = os.path.join(PROJECT, DOC)
    if not os.path.exists(doc_full):
        problems.append("找不到文档: %s" % DOC)
        return decls, "", problems
    with open(doc_full, encoding="utf-8", errors="replace") as fh:
        return decls, fh.read(), problems


def print_summary(gen):
    pf = " / ".join("%s %d" % (rel, gen["per_file"].get(rel, 0)) for rel in NET_FILES)
    print("扫描: %s + %s" % NET_FILES)
    print("声明 %d 条(%s);通道 0/1/2/3 = %d/%d/%d/%d;唯一方法名 %d"
          % (gen["total"], pf, *(gen["channels"][c] for c in TABLE_CHANNELS), gen["unique"]))


def self_test():
    """解析/对账纯函数的自测 —— 每条都答得出「去掉什么它才会红」。"""
    fails = []

    def want(cond, why):
        if not cond:
            fails.append(why)

    # ① 行首 @rpc + 空行隔开的 func 要认;注释里的 @rpc 不算
    code = "\n".join([
        '# 注释里的 @rpc("authority", "call_remote", "reliable", 0) 不算',
        '@rpc("any_peer", "call_remote", "reliable", 0)',
        "",
        "func alpha() -> void:",
        "\tpass",
        "",
        '@rpc("authority", "call_remote", "unreliable", 3)',
        "func beta(x: int) -> void:",
        "\tpass",
    ])
    decls, probs = parse_decls(code, "synthetic.gd")
    want(not probs, "① 正常声明被报问题: %r" % (probs,))
    want([(d["name"], d["channel"]) for d in decls] == [("alpha", 0), ("beta", 3)],
         "① 行首声明 + 空行隔 func 的解析结果不对: %r"
         % ([(d["name"], d["channel"]) for d in decls],))
    # ② 三参(把 int 放第 3 位)必须红 —— 引擎会拒,文本上看不出
    _, probs = parse_decls('@rpc("any_peer", "call_remote", 2)\nfunc gamma() -> void:\n\tpass',
                           "synthetic.gd")
    want(bool(probs), "② 三参 @rpc(引擎会拒的形态)没被报出")
    # ③ 缩进 @rpc 必须点名 —— 否则会被静默漏计
    _, probs = parse_decls('func outer():\n\t@rpc("any_peer", "call_remote", "reliable", 0)\n\tpass',
                           "synthetic.gd")
    want(any("缩进" in p for p in probs), "③ 缩进的 @rpc 没被点名: %r" % (probs,))
    # ④ 跨两个 autoload 同名必须红
    dup = [{"file": NET_FILES[0], "line": 1, "name": "beam_fired", "channel": 3},
           {"file": NET_FILES[1], "line": 2, "name": "beam_fired", "channel": 3}]
    want(bool(duplicate_problems(dup)),
         "④ 同一 RPC 名跨两个 autoload 没被报出 —— 删掉 duplicate_problems() 才会绿")

    # ⑤ 对账:合成「代码声明 + 文档」——一致时无 diff;改坏合计 / 删一条名单必须红
    d2 = [{"file": NET_FILES[0], "line": 1, "name": "alpha", "channel": 0},
          {"file": NET_FILES[1], "line": 2, "name": "beta", "channel": 3}]
    doc_ok = "\n".join([
        "| `transfer_channel` | 实际 ENet 道 | 语义 | 该通道上的 RPC |",
        "|---|---|---|---|",
        "| **0**(默认) | reliable→**0** / unreliable→**1** | 语义 | `alpha` |",
        "| **1** | **2** | 语义 |  |",
        "| **2** | **3** | 语义 |  |",
        "| **3** | **4** | 语义 | `beta` |",
        "",
        "**合计 2 条**:`transfer_channel` 0 = 1 / 1 = 0 / 2 = 0 / 3 = 1。",
        "",
        "作用域:产品声明 **2** 条(`net_bus.gd` 1 + `net_bus_ext.gd` 1);"
        "`transfer_channel` 0/1/2/3 = 1/0/0/1。",
        "",
        "表里 **2** 个方法名 = **2** 条声明,无重名。",
        "",
    ])
    diffs, _, _ = check(d2, doc_ok)
    want(not diffs, "⑤ 一致的合成文档被误报: %r" % (diffs,))
    diffs, _, _ = check(d2, doc_ok.replace("合计 2 条", "合计 3 条"))
    want(any("合计条数" in x for x in diffs), "⑤ 合计改坏没被报出")
    diffs, _, _ = check(d2, doc_ok.replace("| **3** | **4** | 语义 | `beta` |",
                                           "| **3** | **4** | 语义 |  |"))
    want(any("通道 3 名单缺少" in x for x in diffs), "⑤ 通道 3 删掉一条名单没被报出")

    if fails:
        print("— 自测失败 %d 条 —" % len(fails))
        for f in fails:
            print("  " + f)
        print("\n自测 FAIL(修的是 tools/gen_rpc_channel_table.py 本身,不是文档)")
        return 1
    print("自测 OK(注释里的 @rpc 不算 / 空行隔 func 能认 / 三参声明与缩进 @rpc 会红 / "
          "跨 autoload 重名会红 / 合计与通道名单漂移会红)")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if "--check" in argv and "--write" not in argv:
        mode = "check"
    elif "--write" in argv and "--check" not in argv:
        mode = "write"
    else:
        print("用法: python tools/gen_rpc_channel_table.py --check|--write|--self-test")
        return 2
    decls, doc_text, problems = load_inputs()
    diffs, _, gen = check(decls, doc_text, problems)
    print_summary(gen)
    if mode == "check":
        if diffs:
            print("FAIL: %s 与代码声明漂移(%d 项)" % (DOC, len(diffs)))
            for d in diffs:
                print("  - " + d)
            print("修复:手工改表,或 `python tools/gen_rpc_channel_table.py --write`"
                  "(按代码幂等重写表的 RPC 列/合计数字)")
            return 1
        print("OK: %s 与代码声明一致(%d 条 / %s,无跨 autoload 重名)"
              % (DOC, gen["total"], "/".join(str(gen["channels"][c]) for c in TABLE_CHANNELS)))
        return 0
    try:
        new_text, changes = write_doc(decls, doc_text, problems)
    except ValueError as e:
        print("FAIL: %s" % e)
        return 1
    if new_text is None:
        print("OK: 文档已与代码一致,无需改动")
        return 0
    try:
        with open(os.path.join(PROJECT, DOC), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(new_text)
    except OSError as e:
        print("FAIL: 写盘失败(%s);--write 需要能写 %s" % (e, DOC))
        return 1
    print("OK: 已重写 %s(%d 处);再跑 --check 验证" % (DOC, changes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

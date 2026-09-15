#!/usr/bin/env python3
# 命名与目录规范检查(防复发)。规范见 docs/naming-cleanup-plan.md §"采用的规范"。
#
# 为什么需要它:命名整改最典型的失败模式是「整完就漂回去」—— `.tscn` 的 PascalCase 约定
# 就是这么失效的(约定写着 Pascal,现实 51/56 是 snake,而没有任何东西会报错)。
# 2026-09-14 补上 `docs/naming-cleanup-plan.md` 结尾提过、但一直没落地的这一条。
#
# 用法:
#   python tools/check_naming.py            # 检查,有违规 → exit 1(CI/本地都能用)
#   python tools/check_naming.py -v         # 连"已接受的偏差"也列出来
#   python tools/check_naming.py --report   # 只报告不失败(摸底用)
#
# 检查四条:
#   A 目录名一律小写
#   B `class_name` 转 snake 必须等于文件名(规范原文:「名字 = 类名转 snake」)
#   C 文档里引用的文件/目录路径必须存在
#   D `.tscn` 文件名一律 snake_case(阶段 4.3 反转的约定:旧写法 PascalCase 在 51/56 已是
#     snake 的现实下从未生效过)。「有没有同名 .gd 兄弟」仍只作 -v 备注。
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)

# 不参与检查的目录(引擎缓存 / 工具产物 / 归档)
SKIP_DIRS = {".godot", ".git", ".superpowers", ".claude", "builds", "backup",
             "__pycache__", "docs", "assets"}
# 文档路径检查的对象(仓库根的三份文档)
DOC_FILES = ["README.md", "CLAUDE.md", "RELEASE.md"]
# 被文档引用时检查存在性的扩展名
DOC_EXTS = (".gd", ".tscn", ".json", ".js", ".html", ".cyrm", ".cfg",
            ".shader", ".gdshader", ".bat", ".py", ".md", ".ttf", ".otf", ".png")

# ── 已接受的偏差:每条都必须写明**为什么**与**何时销**。
#    这张表只许变短。新增条目 = 承认又欠了一笔技术债,不是"让检查变绿"的手段。
ACCEPTED_CLASS_FILES = {
    "scenes/level_0.gd":
        "类名 Level0 转 snake 是 level0,文件名是 level_0(.tscn 侧已按 4.3 统一为 level_0.tscn;"
        "类名不改 —— 全仓引用 Level0 的点很多,收益不抵改动面)",
}

_fail: list[str] = []
_notes: list[str] = []


def to_snake(name: str) -> str:
    """PascalCase → snake_case,含缩略语:`HUD`→`hud`、`AIInputSource`→`ai_input_source`。"""
    s = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.lower()


def walk_dirs():
    for root, dirs, _files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(root, PROJECT).replace("\\", "/")
        if rel == ".":
            continue
        for d in dirs:
            yield rel + "/" + d


def check_dirs() -> None:
    for path in walk_dirs():
        name = path.rsplit("/", 1)[1]
        if name != name.lower():
            _fail.append("A 目录名不是全小写: %s" % path)


def check_class_names() -> None:
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not f.endswith(".gd"):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, PROJECT).replace("\\", "/")
            if rel.startswith("tests/"):
                continue   # 测试夹具不受类名命名规范约束(多数无 class_name)
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            m = re.search(r"^class_name\s+(\w+)", text, re.M)
            if not m:
                continue
            want = to_snake(m.group(1)) + ".gd"
            if want != f:
                if rel in ACCEPTED_CLASS_FILES:
                    _notes.append("B (已接受) %s: class_name=%s → 期望 %s | %s"
                                  % (rel, m.group(1), want, ACCEPTED_CLASS_FILES[rel]))
                else:
                    _fail.append("B %s: class_name=%s 转 snake 应为 %s" % (rel, m.group(1), want))


def check_doc_paths() -> None:
    seen: set[str] = set()
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        if not os.path.exists(full):
            _fail.append("C 文档不存在: %s(检查表写错了?)" % doc)
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        # ① 反引号里的带扩展名文件路径。
        #    ★ 要求**首段是真实存在的目录**,否则会吃到文档里的简写 —— 例如 CLAUDE.md 的
        #      `kh_l1/l3/l4/l5_probe.tscn`(指 kh_l1_probe / kh_l3_probe / …),那不是路径。
        #      代价:整段目录名都写错的那种(首段也不存在)① 会漏,由 ② 的裸目录检查兜。
        for tok in re.findall(r"`([A-Za-z0-9_./-]+)`", text):
            if "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
            if tok.startswith(("http", "res://")):
                continue
            head = tok.split("/", 1)[0]
            if os.path.isdir(os.path.join(PROJECT, head)):
                seen.add(tok)
        # ② 代码块里以 `dir/` 开头的裸目录名(README 的「目录」段就是这种写法)
        for tok in re.findall(r"^\s*([a-z_]+/)\s", text, re.M):
            seen.add(tok)
    for tok in sorted(seen):
        if not os.path.exists(os.path.join(PROJECT, tok.rstrip("/"))):
            _fail.append("C %s 引用了不存在的路径: %s" % ("/".join(DOC_FILES), tok))


def check_tscn() -> None:
    """`.tscn` 文件名一律 snake_case(阶段 4.3 反转的约定)。

    旧约定写的是 PascalCase,而现实里 51/56 是 snake —— 一条**没人守、也没人报错**的规则,
    于是在文件数翻倍的过程中悄悄失效。现在按现实反转成 snake,并由本检查守住。
    「有没有同名 .gd 兄弟」仍只作备注:武器那 6 个场景是 `weapon_base.gd` 的调参实例,
    本来就不该同名。
    """
    bad, snake, unpaired = [], [], []
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        listing = set(files)          # 用**目录实读列表**判同名,不用 os.path.exists ——
        for f in files:               # 后者在 NTFS 上大小写不敏感,会把 Player.tscn ↔
            if not f.endswith(".tscn"):   # player.gd 误判成"有兄弟"(实测踩过)。
                continue
            rel = os.path.relpath(os.path.join(root, f), PROJECT).replace("\\", "/")
            stem = f[:-5]
            if to_snake(stem) != stem:
                bad.append("%s: .tscn 文件名 %s 不是 snake_case(应为 %s.tscn)"
                           % (rel, stem, to_snake(stem)))
            else:
                snake.append(rel)
            if stem + ".gd" not in listing:
                unpaired.append(rel)
    _fail.extend(bad)
    _notes.append("D .tscn 命名: snake %d 个%s" % (len(snake), "" if not bad else " / **违规 %d 个**" % len(bad)))
    for rel in sorted(unpaired):
        _notes.append("D   无同名 .gd 兄弟(仅备注): %s" % rel)


def main() -> int:
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    report_only = "--report" in sys.argv
    check_dirs()
    check_class_names()
    check_doc_paths()
    check_tscn()
    if _notes and verbose:
        print("— 备注(不判失败,仅 -v 显示) —")
        for n in _notes:
            print("  " + n)
    if _fail:
        print("— 违规 %d 条 —" % len(_fail))
        for f in _fail:
            print("  " + f)
        print("\n命名检查 FAIL(规范见 docs/naming-cleanup-plan.md;"
              "确属有意偏离要加进 ACCEPTED_CLASS_FILES 并写明何时销)")
        return 0 if report_only else 1
    print("命名检查 OK(目录小写 / class_name↔文件名 / 文档路径 / .tscn snake_case)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

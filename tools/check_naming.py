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
#   python tools/check_naming.py --self-test # 检查器**自己**的自测(见 self_test():每条都答得出
#                                            #   "去掉什么它才会红")—— 退出码 0 = 自测通过
#
# 检查四条:
#   A 目录名一律小写
#   B `class_name` 转 snake 必须等于文件名(规范原文:「名字 = 类名转 snake」)
#   C 文档里引用的文件/目录路径必须存在
#   D `.tscn` 文件名一律 snake_case(阶段 4.3 反转的约定:旧写法 PascalCase 在 51/56 已是
#     snake 的现实下从未生效过)。「有没有同名 .gd 兄弟」仍只作 -v 备注。
import os
import re
import shutil
import sys
import tempfile

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)

# 不参与检查的目录(引擎缓存 / 工具产物 / 归档)
# ★ 这张表必须与 .gitignore 对齐:表里没有、而 .gitignore 有的目录(如 releases/ 下带发布标识的
#   归档目录、_crashtest/ 的一次性现场)会让本检查在**干净工作树**上也恒 FAIL ——
#   2026-10-03 实测 5 条 A 类违规全来自这两个目录,与代码无关。
SKIP_DIRS = {".godot", ".git", ".superpowers", ".claude", "builds", "backup",
             "releases", "_crashtest", "__pycache__", "docs", "assets"}
# 文档路径检查的对象(仓库根的三份文档)
# 文档路径检查的对象(仓库根的三份文档 + `CLAUDE.md` 拆出来的分域文档)
DOC_FILES = ["README.md", "CLAUDE.md", "RELEASE.md"] + [
    "docs/eng/%s.md" % n
    for n in ("world", "enemies", "weapons", "player", "render", "ui",
              "netplay", "modes", "tests", "tools", "registered-debt")
]
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


def walk_dirs(base: str = PROJECT):
    """产出 `base` 下所有**参与检查**的目录(相对 base、`/` 分隔、**无前导斜杠**)。

    ★ 2026-10-04 修(审计 §2.10):此前 `rel == "."` 直接 `continue` ⇒ **顶层目录从不被产出**
      ⇒ 规则 A 有盲区,而这个盲区**恰好盖住了唯一的违规**:本仓长期存在大写顶层目录
      `DevTools/`,直到 `9e4ccbe` 把它 `git rm` 出库,规则 A **一次都没报过它**。
      现在顶层与各层一视同仁 —— 顶层产出裸目录名(不带前导 `/`),其余产出 `父/子`。
    ★ `SKIP_DIRS` 与点开头目录的跳过行为**保持不变**(剪枝仍作用于每一层)。
    """
    for root, dirs, _files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(root, base).replace("\\", "/")
        prefix = "" if rel == "." else rel + "/"
        for d in dirs:
            yield prefix + d


def bad_dir_name(name: str) -> bool:
    """规则 A 的**纯函数**形态:目录名是否不合规(必须全小写)。

    抽出来是为了让 `--self-test` 能喂合成名 —— 否则"能红"就只能靠真去建一个大写目录。
    """
    return name != name.lower()


def check_dirs(base: str = PROJECT) -> None:
    for path in walk_dirs(base):
        # `[-1]`:顶层目录的 path 是**裸名**(没有 `/`),用 `[1]` 会 IndexError。
        name = path.rsplit("/", 1)[-1]
        if bad_dir_name(name):
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
    # ★ 2026-10-03:`CLAUDE.md` 拆成索引之后,正文住 `docs/eng/*.md`。**分域文档必须继续被本检查覆盖**
    #   —— 否则"文档引用的路径必须存在"这条会在拆分那一刻**静默失效**(最常见的那种假绿)。
    seen: dict[str, str] = {}          # tok → 引用它的文档(报错要点名)
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        if not os.path.exists(full):
            _fail.append("C 文档不存在: %s(检查表写错了?)" % doc)
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        # ① 反引号里的带扩展名文件路径。
        #    ★ 要求**首段是真实存在的目录**,否则会吃到文档里的简写 —— 例如 docs/eng/tests.md 的
        #      `kh_l1/l3/l4/l5_probe.tscn`(指 kh_l1_probe / kh_l3_probe / …),那不是路径。
        #      代价:整段目录名都写错的那种(首段也不存在)① 会漏,由 ② 的裸目录检查兜。
        for tok in re.findall(r"`([A-Za-z0-9_./-]+)`", text):
            if "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
            if tok.startswith(("http", "res://")):
                continue
            head = tok.split("/", 1)[0]
            if os.path.isdir(os.path.join(PROJECT, head)):
                seen.setdefault(tok, doc)
        # ② 代码块里以 `dir/` 开头的裸目录名(README 的「目录」段就是这种写法)
        for tok in re.findall(r"^\s*([a-z_]+/)\s", text, re.M):
            seen.setdefault(tok, doc)
    for tok in sorted(seen):
        if not os.path.exists(os.path.join(PROJECT, tok.rstrip("/"))):
            _fail.append("C %s 引用了不存在的路径: %s" % (seen[tok], tok))


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


def self_test() -> int:
    """本检查器**自己**的自测 —— 每条断言都答得出「去掉什么它才会红」。

    为什么需要:这个脚本是**全仓守卫**,而守卫最典型的失败模式是"给的保证比读起来少"
    (恒真断言、够不到的分支……)。下面四组断言守的正是 2026-10-04 修掉的那个真盲区:
    `walk_dirs()` 原先在 `rel == "."` 时 `continue` ⇒ **顶层目录名从不被产出** ⇒
    规则 A 对顶层完全失效,曾经存在的大写顶层目录 `DevTools/`(9e4ccbe 才 git rm 出库)
    **一次都没被这条规则报过**(审计 §2.10:"守卫有盲区,恰好盖住唯一的违规")。
    """
    fails: list[str] = []

    def want(cond: bool, why: str) -> None:
        if not cond:
            fails.append(why)

    # ① 真仓库:walk_dirs() 必须产出**已知的顶层目录**(改前顶层被 continue 跳过 ⇒ 必红)。
    real = set(walk_dirs())
    for top in ("tests", "tools", "core"):
        want(top in real, "① walk_dirs() 没产出已知顶层目录 %s —— 顶层仍被跳过?" % top)
    want(not any(p.startswith("/") for p in real),
         "① 产出的路径带了前导 '/': %r" % sorted(p for p in real if p.startswith("/"))[:5])

    # ② 合成树:大写目录名(顶层 + 嵌套)**必须**被规则 A 报出来,且报错文本里顶层不带前导 '/'。
    #    ★ 合成树建在**系统临时目录**而不是仓库根:本仓常有多个会话共用一个工作树(见 AGENTS.md),
    #      把一个大写目录写进仓库根,哪怕只有几毫秒,也会让**别人正在跑的全量检查**报出假违规。
    #      临时区不可写时退回仓库根(自测仍要能跑),用后即删。
    try:
        tmp = tempfile.mkdtemp(prefix="_naming_selftest_")
    except OSError:
        tmp = tempfile.mkdtemp(prefix="_naming_selftest_", dir=PROJECT)
    try:
        for rel in ("DevTools", "tests", ".godot", "builds", "core/Core2", "core/ok"):
            os.makedirs(os.path.join(tmp, rel))
        got = set(walk_dirs(tmp))
        saved = _fail[:]
        _fail.clear()
        try:
            check_dirs(tmp)
            synth = list(_fail)
        finally:
            _fail[:] = saved
        want("A 目录名不是全小写: DevTools" in synth,
             "② 合成的大写顶层目录 DevTools 没被报出(规则 A 的顶层盲区还在): %r" % (synth,))
        want("A 目录名不是全小写: core/Core2" in synth,
             "② 嵌套的大写目录 core/Core2 没被报出: %r" % (synth,))
        want(len(synth) == 2,
             "② 合成树上规则 A 应恰好报 2 条,实得 %d 条: %r" % (len(synth), synth))
        want("DevTools" in got,
             "② walk_dirs() 没产出合成树里的顶层目录 DevTools: %r" % (sorted(got),))

        # ③ 跳过行为**必须不变**:SKIP_DIRS(含 .godot 这类点开头目录)照旧不进产出。
        want(".godot" not in got, "③ 点开头且列在 SKIP_DIRS 的 .godot 没被跳过")
        want("builds" not in got, "③ SKIP_DIRS 里的 builds 没被跳过")
        want(not any(seg in SKIP_DIRS for p in got for seg in p.split("/")),
             "③ 产出里混进了 SKIP_DIRS 的目录: %r" % (sorted(got),))

        # ④ 纯函数本身(规则 A 的判据在大小写,不在路径形态)。
        want(bad_dir_name("DevTools") and bad_dir_name("Core2"),
             "④ bad_dir_name() 没认出大写名")
        want(not bad_dir_name("tests") and not bad_dir_name("core2"),
             "④ bad_dir_name() 误报全小写名")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if fails:
        print("— 自测失败 %d 条 —" % len(fails))
        for f in fails:
            print("  " + f)
        print("\n命名检查自测 FAIL(检查器自身有洞;修的是 tools/check_naming.py 而不是别的)")
        return 1
    print("命名检查自测 OK(顶层目录被产出 / 大写名会被报出 / SKIP_DIRS 与点开头目录照旧跳过)")
    return 0


def main() -> int:
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    report_only = "--report" in sys.argv
    if "--self-test" in sys.argv:
        return self_test()
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

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
#                                            #   "去掉什么它才会红";现覆盖规则 A、C、E)
#                                            #   —— 退出码 0 = 自测通过
#
# 检查五条:
#   A 目录名一律小写
#   B `class_name` 转 snake 必须等于文件名(规范原文:「名字 = 类名转 snake」)
#   C 文档里引用的文件/目录路径必须存在
#   D `.tscn` 文件名一律 snake_case(阶段 4.3 反转的约定:旧写法 PascalCase 在 51/56 已是
#     snake 的现实下从未生效过)。「有没有同名 .gd 兄弟」仍只作 -v 备注。
#   E `.ps1` / `.bat` 的 EOL 必须 CRLF;`.ps1` 还必须「纯 ASCII 或带 UTF-8 BOM」(`.bat` 的编码
#     **不查** —— cmd 把非 ASCII 注释显示成乱码但语义无害,而现存 .bat 里就有中文)。
#     这条是 2026-10-04 补的:规则文字原先写「`.ps1` 保持纯 ASCII」,比现实严、且没机制守(审计 §2.11)。
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
# 文档路径检查的对象 = 仓库根三份 + `docs/eng/`(含 `debt/`)+ `tests/*.md`
# ★ 2026-10-13 改(两步):
#   ① **从写死的 11 个名字改成 glob**。原表在 `CLAUDE.md` 拆分后只覆盖 11 份,而 `docs/eng/`
#      当时已有 23 份 ⇒ 另外 12 份(含 `comment-style.md`、`netcode-*.md`)的路径**无人守**;
#      写死名字的表**每加一份文档就漏一份**(实测:`docs/eng/time.md` 新建当天被检查的次数是**零**)。
#   ② 再纳入 `docs/eng/debt/`(拆分出来的债账分节 —— 它是"动手前先看"的材料)与 `tests/*.md`。
#      ★ 纳入 `debt/` 当天就抓到**78 处相对链接回归**:那些内容从 `docs/eng/` 搬到 `docs/eng/debt/`
#      时,链接没跟着多一层 `../`(搬目录不搬链接 ⇒ 全 404,而此前没有任何检查会红)。
# ★ **刻意不纳入**:`docs/*.md` 的日期交接文档、`docs/superpowers/**`、`docs/archive/**` ——
#   它们按定义是**时间点/历史**文档,里面"刻意的旧路径"是**记录**而不是错误(且都带时效横幅)。
#   **代价照实写**:这些文件里的路径**没有机械守卫**;要查只能手工扫。想彻底解决得按"时效横幅"分档
#   (有横幅 ⇒ 只报"未标已删"的),那是下一步,别顺手把它们全纳入 —— 会把 200+ 条历史记录判红。
def _md_in(rel_dir: str) -> list[str]:
    d = os.path.join(PROJECT, rel_dir)
    if not os.path.isdir(d):
        return []
    return sorted("%s/%s" % (rel_dir, f) for f in os.listdir(d) if f.endswith(".md"))


DOC_FILES = (["README.md", "CLAUDE.md", "RELEASE.md"]
             + _md_in("docs/eng") + _md_in("docs/eng/debt") + _md_in("tests"))
# 被文档引用时检查存在性的扩展名
DOC_EXTS = (".gd", ".tscn", ".json", ".js", ".html", ".cyrm", ".cfg",
            ".shader", ".gdshader", ".bat", ".py", ".md", ".ttf", ".otf", ".png")

# 行号检查(`文件:NNN`)能识别的扩展名 —— 比 DOC_EXTS 宽一点:文档里也会引 `.js`/`.json` 的行号。
LINE_EXTS = (".gd", ".tscn", ".sh", ".py", ".js", ".json", ".cfg", ".tres",
             ".gdshader", ".cs", ".html")
LINE_TOK = re.compile(r'(?<![\w./])([A-Za-z0-9_\-]+\.(?:gd|tscn|sh|py|js|json|cfg|tres|gdshader|cs|html)):(\d+)(?:-(\d+))?')
_BASENAME_INDEX: dict[str, str] = {}


def basename_index() -> dict[str, str]:
    """文件名 → 仓库内**首个**同名的相对路径(惰性、只建一次)。

    用途 = 行号检查:文档写 `player.gd:987-989` 时,需要找到那个文件才能判断行号是否越界。
    ★ 同名多文件时取首个(`warn` 级别的不确定性):本仓目前没有"同名不同目录且都被这样引用"的情形;
      真有的话,行号检查会漏判或误判 —— 所以它只报"**行号超出该文件长度**"这种**一定坏**的情况,
      不做"行号指向的内容对不对"的判断(那需要读内容,不是机械判据)。
    """
    if _BASENAME_INDEX:
        return _BASENAME_INDEX
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), PROJECT).replace("\\", "/")
            _BASENAME_INDEX.setdefault(f, rel)
    return _BASENAME_INDEX


def _line_count(rel: str) -> int:
    try:
        with open(os.path.join(PROJECT, rel), encoding="utf-8", errors="replace") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return -1


_HISTORICAL = ("一次性", "时间点", "不是现行规范", "已封存", "快照")


def is_historical_doc(text: str) -> bool:
    """该文档**自声明**为时间点/快照类 ⇒ 豁免"行号必须存在"检查(但豁免会被**打印出来**,不静默)。"""
    head = text.split("\n## ", 1)[0]
    return any(h in head for h in _HISTORICAL)

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
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        if not os.path.exists(full):
            _fail.append("C 文档不存在: %s(检查表写错了?)" % doc)
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        if is_historical_doc(text):
            _notes.append("C 跳过行号检查(该文档自声明为时间点/快照): %s" % doc)
        for tok in doc_path_violations(text, doc):
            _fail.append("C %s 引用了不存在的路径: %s" % (doc, tok))


def doc_path_violations(text: str, doc: str) -> list[str]:
    """规则 C 的**纯函数**形态:一段文档文本里"指向不存在路径"的引用(返回短标签,供报错点名)。

    抽出来是为了让 `--self-test` 能喂**合成文本** —— 否则"这条规则能不能红"只能靠真去改仓库里的
    文档(与规则 A 抽 `dir_name_violation()` 同款理由)。三处口径各自防一类假绿/假红:

    - **行级豁免**:该行已明说"已删/已移走"就不再要求存在。本仓大量文档在**记录"它已删"**
      (测试面削减台账、注销登记);没有这一半,加固会把这 30 条**正确的历史记录**判违规
      (2026-10-13 实测),等于逼人删掉有价值的信息 —— 那正是"守卫逼人变坏"的形态。
      词表刻意窄:只收"明确表示不在了"的说法。
    - **反引号**:要求首段是真实存在的目录。★ 这一条**只挡得住"首段不是目录"的简写**
      (`kh_l1/l3/l4_probe.tscn` —— 它意指 kh_l1_probe / kh_l3_probe / …);而 `tests/probe/kh_l1/l3/…`
      这种**首段是真目录**的简写**仍会被判违规**,这是**有意**的:那种写法作为路径本就是歧义的,
      该改写成明确的文件名(自测 ⑦-⑦/⑦-⑧ 把这两种形态都钉住了)。
      `:NN` / `:NN-MM` 后缀先剥掉 —— 否则**缀一个行号就能让失效路径绕过检查**(2026-10-13 修的洞:
      `tests/manual/brawl_rollback_probe.gd:55` 因字符类不含 `:` 而整条不匹配,该文件 2026-10-09 已删,
      检查却一直绿)。
    - **markdown 链接目标**(2026-10-13 加):**按所在文档的目录**解析相对路径。原实现只看反引号
      ⇒ 相对链接写错(仓里已 404 过两次,见 `docs/eng/debt/functional-boundaries.md` §五.11)
      没有任何机械守卫。
    """
    GONE = ("已删", "已移除", "已移走", "已移动", "已迁移", "已退休", "已退役",
            "退役", "不存在", "封存", "被取代", "已作废", "过期")
    bad: list[str] = []
    seen: dict[str, bool] = {}          # 路径(或链接解析结果) → 是否不存在
    doc_dir = os.path.dirname(doc)
    historical = is_historical_doc(text)

    def missing(rel: str) -> bool:
        return not os.path.exists(os.path.join(PROJECT, rel.rstrip("/")))

    for line in text.split("\n"):
        if any(g in line for g in GONE):
            continue
        # ③ 行号越界(`文件:NNN` 而该文件没那么多行)—— 2026-10-13 加,见函数头注释。
        #    ★ 自声明为"时间点/快照"的文档**豁免**(但要打印出来,不静默):它们的行号是对**当年那份**
        #      文件的,改掉反而毁掉记录本身。只报"**一定坏**"的情况,不判"行号内容对不对"。
        if not historical:
            for m in LINE_TOK.finditer(line):
                name, a, b = m.group(1), int(m.group(2)), m.group(3)
                rel = basename_index().get(name)
                if rel is None:
                    continue                # 文件不在本仓(netfox / 别条线的工具) ⇒ 无从校验
                n = _line_count(rel)
                if n < 0:
                    continue
                if (int(b) if b else a) > n:
                    key = "%s:%s(越界:该文件只有 %d 行)" % (name, m.group(2) + ("-" + b if b else ""), n)
                    if key not in seen:
                        seen[key] = True
        for tok in re.findall(r"`([A-Za-z0-9_./:-]+)`", line):
            tok = re.sub(r":\d+(-\d+)?$", "", tok)      # 去掉 `:214` / `:214-215` 这类行号后缀
            if ":" in tok or "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
            if tok.startswith(("http", "res://")):
                continue
            if not os.path.isdir(os.path.join(PROJECT, tok.split("/", 1)[0])):
                continue        # 首段不是真目录 ⇒ 是简写,交给 ② 的裸目录检查兜
            if tok not in seen:
                seen[tok] = missing(tok)
        for target in re.findall(r"\]\(([^)]+)\)", line):
            t = target.strip().strip("<>").strip()
            if t == "" or t.startswith(("http://", "https://", "mailto:", "#", "/", "res://")):
                continue
            t = t.split("#", 1)[0]
            if t == "":
                continue
            rel = os.path.normpath(os.path.join(doc_dir, t)).replace("\\", "/")
            if rel not in seen:
                seen[rel] = missing(rel)
    for tok in sorted(seen):
        if seen[tok]:
            bad.append(tok)
    # ② 代码块里以 `dir/` 开头的裸目录名(README 的「目录」段就是这种写法)
    for tok in re.findall(r"^\s*([a-z_]+/)\s", text, re.M):
        if missing(tok):
            bad.append(tok)
    return bad


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


BOM_UTF8 = b"\xef\xbb\xbf"
# 规则 E 覆盖的扩展名 → 是否连**编码**一起核。
#   `.ps1` 核:编码错了 PowerShell 会把中文注释解成乱码(真坏);
#   `.bat` 不核:cmd.exe 对非 ASCII 注释只是显示成乱码,语义无害 —— 而现存 `start_server.bat`
#   就有 7 行中文 ⇒ 去核它**当场假红**,那正是本轮要消灭的"规则比现实严"(审计 §2.11)。
RULE_E_EXTS = {"ps1": True, "bat": False}


def bad_eol_crlf(data: bytes):
    """规则 E 的 EOL 判据:是否**不是**全 CRLF。返回违规原因;`None` = 合规。

    ★ 判法是"**删掉所有 `\\r\\n` 之后,还剩不剩 `\\n` / `\\r`**" —— 只问"有没有 CRLF"会把
      **混用**文件(一半 CRLF、一半裸 LF)放行,那是这个检查最典型的假绿形态。
    """
    lone = data.replace(b"\r\n", b"")
    if b"\n" in lone:
        return "含裸 LF(本类文件必须 CRLF)"
    if b"\r" in lone:
        return "含裸 CR(本类文件必须 CRLF)"
    return None


def bad_ps1_encoding(data: bytes):
    """规则 E 的 `.ps1` 编码判据:纯 ASCII,或带 UTF-8 BOM。返回违规原因;`None` = 合规。

    ★ 为什么不是「必须纯 ASCII」(原 `AGENTS.md` 的写法):那是**比现实严**的规则,而现实早就
      把它违反了 —— `tools/gamelog/capture_session.ps1` 实测 49 行含非 ASCII,靠 UTF-8 BOM
      跑得好好的(没有 BOM 时 Windows PowerShell 5.1 会按 ANSI/GBK 解 ⇒ 中文注释当场变乱码)
      ⇒ 与「绝不扫 [7800,8300)」同一类病:规则文字 ≠ 现实,且没有机制守。
    ★ 最强保证 = 「带 BOM 的非 ASCII 是安全的」这一点被逐文件核过;测不到 = BOM **之后**的字节
      是否合法 UTF-8(只问"有没有 BOM";一个"带 BOM 的 GBK 内容"会漏 —— 现实中不存在,出现再说)。
    """
    if data.startswith(BOM_UTF8):
        return None
    try:
        data.decode("ascii")
    except UnicodeDecodeError:
        return "含非 ASCII 但没有 UTF-8 BOM(无 BOM 时 PowerShell 按 ANSI/GBK 解 ⇒ 中文注释变乱码)"
    return None


def check_ps1_bat(base: str = PROJECT) -> None:
    """规则 E:`.ps1` / `.bat` 逐文件核 EOL(必须 CRLF)与编码(只核 `.ps1`)。

    ★ EOL 这半守的是**工作区落盘形态**:`.gitattributes` 已把 `*.ps1`/`*.bat` 钉成 `eol=crlf`
      ⇒ checkout 出来就是 CRLF(实测 `git ls-files --eol` 是 `i/lf w/crlf`:git 在 `add` 时把
      CRLF 归一成 LF 存库)。红了**不要**手改内容,重新落盘即可:`rm <file> && git checkout -- <file>`
      (★ 单纯 `git checkout -- <file>` 是**空操作** —— 文件在 git 眼里是干净的,实测过)。
    ★ 编码那半守的是**内容**:BOM 是字节,git 不会动它 ⇒ 这半才是真守住了"中文注释别被解成乱码"。
    """
    checked = {ext: 0 for ext in RULE_E_EXTS}
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
            if ext not in RULE_E_EXTS:
                continue
            full = os.path.join(root, f)
            try:
                data = open(full, "rb").read()
            except OSError:
                continue
            checked[ext] += 1
            why = bad_eol_crlf(data)
            if why is None and RULE_E_EXTS[ext]:
                why = bad_ps1_encoding(data)
            if why:
                rel = os.path.relpath(full, base).replace("\\", "/")
                _fail.append("E %s: %s" % (rel, why))
    _notes.append("E .ps1 %d 个 / .bat %d 个:EOL 逐文件核 CRLF;编码只核 .ps1(纯 ASCII 或带 BOM)"
                  % (checked["ps1"], checked["bat"]))


def self_test() -> int:
    """本检查器**自己**的自测 —— 每条断言都答得出「去掉什么它才会红」。

    为什么需要:这个脚本是**全仓守卫**,而守卫最典型的失败模式是"给的保证比读起来少"
    (恒真断言、够不到的分支……)。下面六组断言守的正是 2026-10-04 修掉的两个真盲区:
    - ①②③④ 规则 A:`walk_dirs()` 原先在 `rel == "."` 时 `continue` ⇒ **顶层目录名从不被产出**
      ⇒ 规则 A 对顶层完全失效,曾经存在的大写顶层目录 `DevTools/`(9e4ccbe 才 git rm 出库)
      **一次都没被这条规则报过**(审计 §2.10:"守卫有盲区,恰好盖住唯一的违规")。
    - ⑤⑥ 规则 E:`.ps1`/`.bat` 的 EOL 与 `.ps1` 的编码,原先**一个字都没有**(审计 §2.11:
      规则写着"必须纯 ASCII",而 `capture_session.ps1` 有 49 行中文,谁也没报过)。
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

    # ⑤ 规则 E 的两条判据(**纯函数**形态):合成字节。判据口径 = 控制器 2026-10-04 定的那张表:
    #    `.ps1` = 必须 CRLF + (纯 ASCII 或带 BOM);`.bat` = 必须 CRLF、编码不查。
    want(bad_eol_crlf(b"echo hi\n") is not None,
         "⑤-① 裸 LF、无 BOM 没被报出 —— 去掉 bad_eol_crlf() 的裸-LF 分支才会红")
    want(bad_eol_crlf(b"echo hi\r\n") is None,
         "⑤-① 纯 ASCII + CRLF 被误报")
    want(bad_eol_crlf(b"a\r\nb\nc\r\n") is not None,
         "⑤-① 混用(有 CRLF 也有裸 LF)被放行 —— 判据只问'有没有 CRLF'就会漏这条")
    want(bad_eol_crlf(b"a\rb") is not None,
         "⑤-① 裸 CR(旧 Mac 行尾 / 被拆开的 CRLF)没被报出 —— 去掉 bad_eol_crlf() 的裸-CR 分支才会红")
    want(bad_ps1_encoding(BOM_UTF8 + "写一句中文".encode("utf-8")) is None,
         "⑤-② 'BOM + 非 ASCII' 被误报 —— 那正是 capture_session.ps1 的现实形态(49 行中文)")
    want(bad_ps1_encoding(b"echo hi") is None,
         "⑤-③ 纯 ASCII 被误报")
    want(bad_ps1_encoding("写一句中文".encode("utf-8")) is not None,
         "⑤-④ 非 ASCII 且无 BOM 没被报出 —— 删掉 bad_ps1_encoding() 的编码判定才会红")

    # ⑥ 再走一遍**真的文件树**(临时目录):只喂纯函数不够 —— 那样"walk 里根本没接上这条规则"
    #    也照样全绿。这里同时覆盖扩展名过滤 + `.ps1` 查编码 / `.bat` 不查编码的分工。
    tmp_e = tempfile.mkdtemp(prefix="_naming_selftest_e_")   # 同 ②:合成树放系统临时区,别写进仓库根
    try:
        samples = {
            "a.ps1": b"echo hi\n",                                    # 裸 LF ⇒ 报
            "b.ps1": BOM_UTF8 + "写一句中文\r\n".encode("utf-8"),       # BOM + 非 ASCII ⇒ **不**报
            "c.ps1": b"echo hi\r\n",                                   # 纯 ASCII + CRLF ⇒ 不报
            "d.ps1": "写一句中文\r\n".encode("utf-8"),                  # 非 ASCII 无 BOM ⇒ 报
            "e.bat": b"@echo off\n",                                   # .bat 裸 LF ⇒ 报
            "f.bat": "rem 中文注释\r\n".encode("utf-8"),                # .bat 非 ASCII 无 BOM ⇒ **不**报
            "g.txt": b"echo hi\n",                                     # 别的扩展名 ⇒ 不看
        }
        for name, data in samples.items():
            with open(os.path.join(tmp_e, name), "wb") as fh:
                fh.write(data)
        saved_e = _fail[:]
        saved_notes = _notes[:]     # 连 _notes 一起存:自测不该往"本轮备注"里写东西
        _fail.clear()
        _notes.clear()
        try:
            check_ps1_bat(tmp_e)
            e_fails = list(_fail)
        finally:
            _fail[:] = saved_e
            _notes[:] = saved_notes
        want(any(x.startswith("E a.ps1:") for x in e_fails),
             "⑥ 合成树:裸 LF 的 a.ps1 没被报出(规则 E 没接进 walk): %r" % (e_fails,))
        want(any(x.startswith("E d.ps1:") for x in e_fails),
             "⑥ 合成树:非 ASCII 无 BOM 的 d.ps1 没被报出: %r" % (e_fails,))
        want(any(x.startswith("E e.bat:") for x in e_fails),
             "⑥ 合成树:裸 LF 的 e.bat 没被报出: %r" % (e_fails,))
        want(len(e_fails) == 3,
             "⑥ 合成树:规则 E 应恰好报 3 条(a.ps1 裸 LF / d.ps1 无 BOM / e.bat 裸 LF),"
             "实得 %d 条: %r" % (len(e_fails), e_fails))
        want(not any("f.bat" in x for x in e_fails),
             "⑥ .bat 的**编码**不该查(cmd 对非 ASCII 注释只是乱码;现存 .bat 就有中文)"
             " —— 却报了: %r" % (e_fails,))
        want(not any("g.txt" in x for x in e_fails),
             "⑥ 非 .ps1/.bat 的 g.txt 被规则 E 吃进来了")
    finally:
        shutil.rmtree(tmp_e, ignore_errors=True)

    # ⑦ 规则 C(**纯函数**形态,2026-10-13 加):喂合成文本 —— 这是台账点名的欠账
    #    (`docs/eng/debt/functional-boundaries.md` §五.12:"并配一条**能红**的自测")。
    #    每条都答得出"去掉什么才会红"。
    want(len(doc_path_violations("见 `tests/nope_xyz.gd`", "docs/eng/x.md")) == 1,
         "⑦-① 不存在的反引号路径没被报出 —— 删掉 doc_path_violations() 的反引号分支才会绿")
    want(len(doc_path_violations("见 `tests/nope_xyz.gd:55`", "docs/eng/x.md")) == 1,
         "⑦-② 带 `:55` 行号后缀的失效路径没被报出 —— 去掉剥 `:NN` 的那行就会红(2026-10-13 修的洞)")
    want(len(doc_path_violations("见 `core/sim/world_rewind.gd`", "docs/eng/x.md")) == 0,
         "⑦-③ 真实存在的路径被误报")
    want(len(doc_path_violations("[计划](../superpowers/plans/2026-10-04-tile-destruction-consistency.md)",
                                 "docs/eng/x.md")) == 0,
         "⑦-④ 正确的相对链接被误报 —— 链接目标按**所在目录**解析,别按仓库根")
    want(len(doc_path_violations("[计划](superpowers/plans/2026-10-04-tile-destruction-consistency.md)",
                                 "docs/eng/x.md")) == 1,
         "⑦-⑤ 少一层的相对链接(真 404,仓里犯过两次)没被报出 —— 去掉链接分支才会绿")
    want(len(doc_path_violations("`tests/manual/brawl_rollback_probe.gd`（已删·2026-10-09）",
                                 "docs/eng/x.md")) == 0,
         "⑦-⑥ 已明说'已删'的行仍被判违规 —— 没有行级豁免会把 30 条正确的历史记录判红,逼人删信息")
    want(len(doc_path_violations("`kh_l1/l3/l4_probe.tscn`", "docs/eng/x.md")) == 0,
         "⑦-⑦ 首段不是真目录的简写被误报 —— '首段是目录'这条启发式该挡住的正是这一形态")
    want(len(doc_path_violations("`tests/probe/kh_l1/l3/l4_probe.tscn`", "docs/eng/x.md")) == 1,
         "⑦-⑧ 首段是真目录的简写没被报出 —— ★ 这是**有意**判违规的(歧义路径该改写成明确文件名);"
         "若哪天想放行它,必须先想清楚'歧义简写'与'真路径'怎么区分,别顺手把 ⑦-① 一起放行")
    # ⑧ 行号越界(2026-10-13 加第三条判据):`文件:NNN` 而该文件没那么多行。
    want(len(doc_path_violations("见 `player.gd:99999`", "docs/eng/x.md")) == 1,
         "⑧-① 行号越界没被报出 —— 删掉规则 C 里 ③ 那一段就会绿")
    want(len(doc_path_violations("见 `player.gd:1-2`", "docs/eng/x.md")) == 0,
         "⑧-② 正常范围内的行号被误报")
    want(len(doc_path_violations("外部的 `network-time.gd:9999`(不在本仓)", "docs/eng/x.md")) == 0,
         "⑧-③ 本仓没有的文件被拿去查行号 —— 无从校验,应跳过")
    want(len(doc_path_violations("# 某报告\n\n> 这是一次性**时间点**快照,不是现行规范。\n\n见 `player.gd:99999`",
                                 "docs/eng/x.md")) == 0,
         "⑧-④ 自声明为时间点/快照的文档没被豁免 —— 它的行号是对**当年那份**文件的,改掉反而毁记录;"
         "豁免必须能红:去掉 is_historical_doc() 就会绿")

    if fails:
        print("— 自测失败 %d 条 —" % len(fails))
        for f in fails:
            print("  " + f)
        print("\n命名检查自测 FAIL(检查器自身有洞;修的是 tools/check_naming.py 而不是别的)")
        return 1
    print("命名检查自测 OK(规则 A:顶层目录被产出 / 大写名会被报出 / SKIP_DIRS 与点开头目录照旧跳过;"
          "规则 C:失效反引号路径、带 `:NN` 后缀的、少一层的相对链接都会被报出,而已删行与'首段非目录'的简写不报;"
          "规则 E:裸 LF 与非 ASCII 无 BOM 会被报出 / BOM+非 ASCII 与纯 ASCII+CRLF 不报 / .bat 不查编码)")
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
    check_ps1_bat()
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
    print("命名检查 OK(目录小写 / class_name↔文件名 / 文档路径 / .tscn snake_case / "
          ".ps1·.bat 的 CRLF 与 .ps1 编码)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# 命名与目录规范自动化检查工具。
# 检验项目内的目录名、GDScript 类名映射、文档路径有效性以及场景文件名规范。
#
# 用法:
#   python tools/check_naming.py            # 执行检查，发现违规时退出码为 1
#   python tools/check_naming.py -v         # 详细模式，输出已登记的兼容项
#   python tools/check_naming.py --report   # 仅输出报告，不阻断退出码
#
# 检查项说明:
#   A 目录名一律使用小写
#   B class_name 声明转 snake_case 后需与当前文件名一致
#   C 文档中引用的工程内相对文件与目录路径必须真实存在
#   D .tscn 场景文件名统一使用 snake_case
#   E PowerShell/BAT 换行与 PowerShell 编码
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)

# 排除检查的目录（引擎构建缓存、版本控制、构建产物与临时目录）
# 与版本忽略规则保持一致，避免构建和运行临时文件引发偶发误报
SKIP_DIRS = {".test_logs", ".godot", ".git", ".superpowers", ".claude", "builds", "backup",
             "releases", "_crashtest", "__pycache__", "docs", "assets"}
# 按当前目录发现文档，不为新增域文档维护第二张清单。
DOC_FILES = sorted(p.relative_to(PROJECT).as_posix() for p in [
    *Path(PROJECT).glob("*.md"), *Path(PROJECT, "docs", "eng").rglob("*.md"),
])
# 被文档引用时检查存在性的扩展名
DOC_EXTS = (".gd", ".tscn", ".json", ".js", ".html", ".cyrm", ".cfg",
            ".shader", ".gdshader", ".bat", ".py", ".md", ".ttf", ".otf", ".png")
GENERATED_DOC_PREFIXES = (".test_logs/", "builds/", "releases/", "level_editor/dist/")

# 已确认的特殊命名豁免项，记录文件路径与保留现有名称的技术原因
ACCEPTED_CLASS_FILES = {
    "scenes/level_0.gd":
        "类名 Level0 转为 snake_case 对应 level0，当前文件名为 level_0；"
        "由于全仓多处核心模块引用 Level0 类名，为保持稳定性暂不调整类名",
}
ACCEPTED_DIRS = {}

_fail: list[str] = []
_notes: list[str] = []


def to_snake(name: str) -> str:
    """将 PascalCase 转换为 snake_case，支持常见缩写命名。"""
    s = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.lower()


def walk_dirs():
    for root, dirs, _files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(root, PROJECT).replace("\\", "/")
        for d in dirs:
            yield d if rel == "." else rel + "/" + d


def check_dirs() -> None:
    for path in walk_dirs():
        name = path.rsplit("/", 1)[-1]
        if name != name.lower():
            if path in ACCEPTED_DIRS:
                _notes.append("A (已接受) %s: %s" % (path, ACCEPTED_DIRS[path]))
            else:
                _fail.append("A 目录名不是全小写: %s" % path)


def check_class_names() -> None:
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not f.endswith(".gd"):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, PROJECT).replace("\\", "/")
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


def markdown_issues(doc: Path, text: str, project: Path) -> list[str]:
    """Markdown 链接相对于所在文档解析；忽略网址、锚点及代码块。"""
    issues = []
    prose = re.sub(r"^```[^\n]*\n.*?^```[^\n]*$", "", text, flags=re.M | re.S)
    for match in re.finditer(r"\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+\"[^\"]*\")?\s*\)", prose):
        target = unquote(match.group(1) or match.group(2))
        if not target or target.startswith("#"):
            continue
        if target.startswith("res://"):
            target = target[6:]
            base = project
        elif urlsplit(target).scheme:
            continue
        else:
            base = doc.parent
        location, _, anchor = target.partition("#")
        line_match = re.search(r":([1-9]\d*)$", location)
        line = int(line_match[1]) if line_match else None
        if line_match:
            location = location[:line_match.start()]
        elif re.fullmatch(r"L\d+(?:-L\d+)?", anchor):
            line = int(anchor[1:].split("-")[0])
        path = (base / location).resolve()
        if not path.is_relative_to(project.resolve()):
            continue  # 工程外参考文件不是仓库的可移植性约束。
        if not path.exists():
            issues.append("链接目标不存在: " + target)
        elif line is not None and path.is_file():
            count = len(path.read_text(encoding="utf-8", errors="replace").splitlines())
            if line > count:
                issues.append("链接行号越界: %s(共 %d 行)" % (target, count))
    return issues


def check_doc_paths() -> None:
    # 覆盖根文档以及各分域文档中引用的本地工程路径，防止出现无效死链
    seen: dict[str, str] = {}          # 路径标识与来源文档映射
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        if not os.path.exists(full):
            _fail.append("C 文档不存在: %s(检查表配置路径有误)" % doc)
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        _fail.extend("C %s %s" % (doc, issue) for issue in markdown_issues(Path(full), text, Path(PROJECT)))
        # 反引号包裹的带扩展名相对路径
        # 验证路径首级目录存在，避免误伤文档中的复合简写
        for tok in re.findall(r"`([A-Za-z0-9_./-]+)`", text):
            if "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
            if tok.startswith(GENERATED_DOC_PREFIXES):
                continue  # 文档可说明尚未生成的产物，不要求干净检出时已存在。
            if tok.startswith(("http", "res://")):
                continue
            head = tok.split("/", 1)[0]
            if os.path.isdir(os.path.join(PROJECT, head)):
                seen.setdefault(tok, doc)
        # 代码块中行首以目录格式命名的路径
        for tok in re.findall(r"^\s*([a-z_]+/)\s", text, re.M):
            seen.setdefault(tok, doc)
    for tok in sorted(seen):
        if not os.path.exists(os.path.join(PROJECT, tok.rstrip("/"))):
            _fail.append("C %s 引用了不存在的路径: %s" % (seen[tok], tok))


def check_tscn() -> None:
    """检查场景文件名是否统一遵循 snake_case 命名规范。"""
    bad, snake, unpaired = [], [], []
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        listing = set(files)          # 读取当前目录真实文件列表判定同名脚本
        for f in files:               # 避免不区分大小写的文件系统引起判定偏差
            if not f.endswith(".tscn"):
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
    _notes.append("D .tscn 命名: snake %d 个%s" % (len(snake), "" if not bad else " / 违规 %d 个" % len(bad)))
    for rel in sorted(unpaired):
        _notes.append("D   无同名 .gd 兄弟(仅备注): %s" % rel)


def script_encoding_issues(data: bytes, suffix: str) -> list[str]:
    issues = []
    if b"\n" in data.replace(b"\r\n", b"") or b"\r" in data.replace(b"\r\n", b""):
        issues.append("应使用 CRLF 换行")
    if suffix == ".ps1":
        if not data.startswith(b"\xef\xbb\xbf") and not data.isascii():
            issues.append("非 ASCII PowerShell 脚本应带 UTF-8 BOM")
        try:
            data.decode("utf-8-sig")
        except UnicodeDecodeError:
            issues.append("PowerShell 脚本不是有效 UTF-8")
    return issues


def check_script_encodings() -> None:
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            suffix = Path(name).suffix.lower()
            if suffix not in (".ps1", ".bat"):
                continue
            file = Path(root, name)
            _fail.extend("E %s: %s" % (file.relative_to(PROJECT), issue)
                         for issue in script_encoding_issues(file.read_bytes(), suffix))


def main() -> int:
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    report_only = "--report" in sys.argv
    check_dirs()
    check_class_names()
    check_doc_paths()
    check_tscn()
    check_script_encodings()
    if _notes and verbose:
        print("— 备注(不判失败,仅 -v 显示) —")
        for n in _notes:
            print("  " + n)
    if _fail:
        print("— 违规 %d 条 —" % len(_fail))
        for f in _fail:
            print("  " + f)
        print("\n命名检查 FAIL(规范见 AGENTS.md；有意保留的类名差异应登记原因)")
        return 0 if report_only else 1
    print("命名检查 OK(目录小写 / class_name↔文件名 / 文档链接与行号 / .tscn snake_case / 脚本编码)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# 检查项目文件的命名、文档引用以及脚本的字符编码和换行符。
# -v 同时列出提示信息。--report 只报告问题，退出码仍为 0。
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

# 下列目录不参与文件名和脚本检查，包括工具缓存、构建输出和游戏资源。
SKIP_DIRS = {".test_logs", ".godot", ".git", ".superpowers", ".claude", "builds", "backup",
             "releases", "_crashtest", "__pycache__", "docs", "assets"}
DOC_FILES = sorted(p.name for p in Path(PROJECT).glob("*.md"))
# 识别反引号中的文件路径时，只考虑下列扩展名。
DOC_EXTS = (".gd", ".tscn", ".json", ".js", ".html", ".cyrm", ".cfg",
            ".shader", ".gdshader", ".bat", ".py", ".md", ".ttf", ".otf", ".png")
GENERATED_DOC_PREFIXES = (".test_logs/", "builds/", "releases/")

_fail: list[str] = []
_notes: list[str] = []


def to_snake(name: str) -> str:
    """将 PascalCase 名称转为小写下划线形式，并把连续大写缩写视为一个词。"""
    s = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.lower()


def markdown_issues(doc: Path, text: str, project: Path) -> list[str]:
    """检查 Markdown 链接的目标文件与行号。相对链接以当前文档所在目录为基准。"""
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
            continue  # 仓库外的文件不在检查范围内。
        if not path.exists():
            issues.append("链接目标不存在: " + target)
        elif line is not None and path.is_file():
            count = len(path.read_text(encoding="utf-8", errors="replace").splitlines())
            if line > count:
                issues.append("链接行号越界: %s(共 %d 行)" % (target, count))
    return issues


def check_doc_paths() -> None:
    # 除 Markdown 链接外，也识别文档中以代码格式列出的路径和行首目录名。
    seen: dict[str, str] = {}          # 用第一次出现该路径的文档定位报错。
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        text = open(full, encoding="utf-8", errors="replace").read()
        _fail.extend("C %s %s" % (doc, issue) for issue in markdown_issues(Path(full), text, Path(PROJECT)))
        # 反引号中的代码片段可能形似路径。只有目录开头已存在于仓库中的项才会作为路径检查。
        for tok in re.findall(r"`([A-Za-z0-9_./-]+)`", text):
            if "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
            if tok.startswith(GENERATED_DOC_PREFIXES):
                continue  # 允许文档引用当前尚未生成的输出文件。
            if tok.startswith(("http", "res://")):
                continue
            head = tok.split("/", 1)[0]
            if os.path.isdir(os.path.join(PROJECT, head)):
                seen.setdefault(tok, doc)
        # 把行首形如 目录/ 的引用也记入检查清单。
        for tok in re.findall(r"^\s*([a-z_]+/)\s", text, re.M):
            seen.setdefault(tok, doc)
    for tok in sorted(seen):
        if not os.path.exists(os.path.join(PROJECT, tok.rstrip("/"))):
            _fail.append("C %s 引用了不存在的路径: %s" % (seen[tok], tok))


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


def check_tree() -> None:
    scenes = 0
    unpaired = []
    for root, dirs, names in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        folder = Path(root)
        for name in dirs:
            if name != name.lower():
                _fail.append(f"A 目录名不是全小写: {(folder / name).relative_to(PROJECT)}")
        for name in names:
            path = folder / name
            rel = path.relative_to(PROJECT).as_posix()
            if path.suffix == ".gd":
                match = re.search(r"^class_name\s+(\w+)", path.read_text(encoding="utf-8", errors="replace"), re.M)
                if match and path.stem != to_snake(match[1]):
                    _fail.append(f"B {rel}: class_name={match[1]} 应为 {to_snake(match[1])}.gd")
            elif path.suffix == ".tscn":
                scenes += 1
                if path.stem != to_snake(path.stem):
                    _fail.append(f"D {rel}: 场景名应为 {to_snake(path.stem)}.tscn")
                if path.stem + ".gd" not in names:
                    unpaired.append(rel)
            elif path.suffix.lower() in (".ps1", ".bat"):
                _fail.extend(f"E {rel}: {issue}" for issue in script_encoding_issues(path.read_bytes(), path.suffix.lower()))
    _notes.append(f"D .tscn 场景 {scenes} 个")
    _notes.extend(f"D   无同名 .gd 兄弟(仅备注): {rel}" for rel in sorted(unpaired))


def main() -> int:
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    report_only = "--report" in sys.argv
    check_tree()
    check_doc_paths()
    if _notes and verbose:
        print("— 备注(不判失败,仅 -v 显示) —")
        for n in _notes:
            print("  " + n)
    if _fail:
        print("— 违规 %d 条 —" % len(_fail))
        for f in _fail:
            print("  " + f)
        print("\n命名检查 FAIL")
        return 0 if report_only else 1
    print("命名检查 OK(目录小写 / class_name↔文件名 / 文档链接与行号 / .tscn snake_case / 脚本编码)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

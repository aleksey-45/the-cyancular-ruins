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
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)

# 排除检查的目录（引擎构建缓存、版本控制、构建产物与临时目录）
# 与版本忽略规则保持一致，避免构建和运行临时文件引发偶发误报
SKIP_DIRS = {".godot", ".git", ".superpowers", ".claude", "builds", "backup",
             "releases", "_crashtest", "__pycache__", "docs", "assets"}
# 文档路径检查的对象（项目根文档与核心分域技术文档）
DOC_FILES = ["README.md", "CLAUDE.md", "RELEASE.md"] + [
    "docs/eng/%s.md" % n
    for n in ("world", "enemies", "weapons", "player", "render", "ui",
              "netplay", "modes", "tests", "tools", "registered-debt")
]
# 被文档引用时检查存在性的扩展名
DOC_EXTS = (".gd", ".tscn", ".json", ".js", ".html", ".cyrm", ".cfg",
            ".shader", ".gdshader", ".bat", ".py", ".md", ".ttf", ".otf", ".png")

# 已确认的特殊命名豁免项，记录文件路径与保留现有名称的技术原因
ACCEPTED_CLASS_FILES = {
    "scenes/level_0.gd":
        "类名 Level0 转为 snake_case 对应 level0，当前文件名为 level_0；"
        "由于全仓多处核心模块引用 Level0 类名，为保持稳定性暂不调整类名",
}

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
                continue   # 测试脚本不受类名命名规范约束（多数无 class_name）
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
    # 覆盖根文档以及各分域文档中引用的本地工程路径，防止出现无效死链
    seen: dict[str, str] = {}          # 路径标识与来源文档映射
    for doc in DOC_FILES:
        full = os.path.join(PROJECT, doc)
        if not os.path.exists(full):
            _fail.append("C 文档不存在: %s(检查表配置路径有误)" % doc)
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        # 反引号包裹的带扩展名相对路径
        # 验证路径首级目录存在，避免误伤文档中的复合简写
        for tok in re.findall(r"`([A-Za-z0-9_./-]+)`", text):
            if "/" not in tok or not tok.endswith(DOC_EXTS):
                continue
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

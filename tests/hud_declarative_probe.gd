extends ProbeBase

# 声明式 HUD 契约守卫(阶段:UI 代码生成节点搬进 .tscn)。
#
# 守的是什么:凡「由 .tscn 声明节点、脚本只 @onready 取」的界面,
#   ① 宿主必须用 (load/preload(...tscn)).instantiate() 建,**绝不** <类>.new();
#   ② 脚本里每个 `@onready var x = $A/B/C` 的**叶子名** C,必须在配套 .tscn 里
#      有 `[node name="C"` 声明。
# 为什么值一条探针:.new() 建出来的节点**没有子节点**,而声明式脚本的 _ready 会直接
#   解引用它们 → 硬崩溃。这不是假设 —— tests/kh_l6_probe.gd 第 10 条记的正是 B11
#   (pvp_hud 那次)。本探针把同一份契约扩到后续搬的三套;kh_l6 第 10 条仍只守 pvp_hud,
#   **不要去改它**(改一条已绿的探针收益低于风险)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn
# 判据:末行 "KH HUD PROBE: ALL-OK"(grep 文本,不看退出码)。
#
# ★ 注意本文件是源码级探针,但被 kh_l4/kh_l5 的字号扫描覆盖(res://tests 在 ALL_DIRS 里)
#   —— 正文里不许出现非 16 倍数的字号载体字面量。本文件没有字号,安全。

# [脚本, 配套 tscn, 类名] —— 每搬一套加一行
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
	["res://ui/combat_feedback.gd", "res://ui/combat_feedback.tscn", "CombatFeedback"],
]

# 参数下限:防止 PAIRS 被误删成空表 → 零循环 → 恒绿
const MIN_PAIRS := 2

# @onready var <名>[: 类型] = $<路径>   → 捕获组 2 = 路径
const RE_ONREADY := "@onready\\s+var\\s+(\\w+)\\s*(?::\\s*[\\w\\[\\]]+\\s*)?=\\s*\\$([\\w/]+)"


func probe_id() -> String:
	return "HUD"


func _ready() -> void:
	var before := _failures.size()
	_check(PAIRS.size() >= MIN_PAIRS,
			"PAIRS 只剩 %d 组(判据退化:至少要有 %d 组,否则本探针变成恒绿)" % [PAIRS.size(), MIN_PAIRS])
	for p in PAIRS:
		_check_pair(str(p[0]), str(p[1]), str(p[2]))
	_summary(before, "声明式契约:扫 %d 组「脚本 ↔ 场景」,零 .new()、@onready 路径全声明" % PAIRS.size())
	_finish()


func _check_pair(script_path: String, tscn_path: String, cls: String) -> void:
	var before := _failures.size()
	var exists := ResourceLoader.exists(tscn_path)
	_check(exists, "%s 不存在(%s 声称自己走声明式场景,却没有配套 tscn)" % [tscn_path, script_path])
	if not exists:
		_summary(before, "%s:场景缺失,跳过" % script_path)
		return
	var code := _code_only(_read(script_path))
	var tscn := _read(tscn_path)
	_check(not code.is_empty(), "读不到 %s" % script_path)
	if code.is_empty() or tscn.is_empty():
		_summary(before, "%s:读文件失败" % script_path)
		return

	# ① 全文不得出现 <类>.new(
	var re_new := RegEx.new()
	re_new.compile("\\b" + cls + "\\.new\\(")
	var hits := re_new.search_all(code)
	_check(hits.is_empty(),
			"%s 里出现 %s.new( 共 %d 处(声明式脚本不能用 .new():建出来的节点没有子节点,_ready 解引用必崩)" % [
					script_path, cls, hits.size()])

	# ② @onready $路径 的叶子名必须在 tscn 里声明
	var re := RegEx.new()
	re.compile(RE_ONREADY)
	var paths := re.search_all(code)
	_check(paths.size() >= 1,
			"%s 的 @onready $子节点 解析出 %d 个(判据可能退化成恒绿:一个 $路径都没有)" % [script_path, paths.size()])
	var missing: Array[String] = []
	for m in paths:
		var leaf: String = (m.get_string(2) as String).split("/")[-1]
		if not tscn.contains("[node name=\"" + leaf + "\""):
			missing.append(leaf)
	_check(missing.is_empty(),
			"%s 的 @onready 子节点 %s 在 %s 里没有声明(契约破了 → 运行期解引用 null)" % [
					script_path, ", ".join(missing), tscn_path])
	_summary(before, "%s ↔ %s:%d 个 @onready 子节点全声明、零 %s.new(" % [
			script_path, tscn_path, paths.size(), cls])

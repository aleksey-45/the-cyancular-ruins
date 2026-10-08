extends SceneTree
# RPC 通道契约自检(closeout 批 Task 5)。
#
# ★★ **这是代理判据,不是行为证据** —— 按 `docs/eng/test-economy.md` 的 **D6b**,这类文本对账必须标注:
#   它读的是"**声明文本有没有按表写**",**不是**"分流真的生效了"。本文件头把上限写清楚,是为了让
#   下一个人不会把它的 OK 读成"通道分流已验证"。
#
# **为什么只能是文本对账**:通道号**无法在运行期回读** —— 实测(2026-10-08)
#   `GDScript.get_script_method_list()` 的元素键只有 `["name","args","default_args","flags","id","return"]`,
#   **没有** `rpc_config`;而 `@rpc` 注解只吃**字面量**(不能引用 const)⇒ 声明与表天然是两份文本。
#   要**行为级**证明"分流生效",得让两个 peer 分别占不同通道对打(今天**没有**这条路径 ⇒ 覆盖上限,
#   登记在 `docs/eng/netplay.md` 的通道表一节)。
#
# **判据(两条,各自独立)**:
#   ① `docs/eng/netplay.md` 的通道表 ↔ 产品声明**逐条同通道**(漏的、多的、通道不符的都红);
#   ② 每条声明必须是**四参形态** `@rpc("<mode>", "call_remote", "<transfer_mode>", <通道>)`
#      —— ★ 实测:只写三参并把 int 放第 3 位会被引擎拒(`argument 3 should be "String" but is "int"`)。
# 作用域 = 产品声明 59 条(`net_bus.gd` 28 + `net_bus_ext.gd` 31);`tests/smoke/reconnect_smoke.gd`
#   的 13 条是**测试桩自己的 RPC**,显式排除并把条数打印出来。
# 通过 = `RPC CHANNEL CONTRACT OK` 退出 0。

const TABLE_MD := "res://docs/eng/netplay.md"
const PRODUCT_FILES := ["res://core/net/net_bus.gd", "res://core/net/net_bus_ext.gd"]
const SCOPE_DECLARATIONS := 59   # ★ 会变的枚举:对不上就红,逼人回来核(见 --list / 报告)

var _fails: Array[String] = []
var _checks := 0

func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# 解析 `docs/eng/netplay.md` 的通道表:每行形如 `| **0** | 语义 | 为什么 | \`a\` / \`b\` |`
func _parse_table() -> Dictionary:
	var out := {}
	var f := FileAccess.open(TABLE_MD, FileAccess.READ)
	if f == null:
		return out
	var in_table := false
	for line in f.get_as_text().split("\n"):
		if line.begins_with("| **") and line.contains(" | "):
			var m := line.split("|")
			# ["", " **0** ", " 语义 ", " 为什么 ", " `a` / `b` ", ""]
			if m.size() < 6:
				continue
			var ch_txt := m[1].strip_edges().trim_prefix("**").trim_suffix("**")
			if not ch_txt.is_valid_int():
				continue
			var ch := int(ch_txt)
			for tok in m[4].split("`"):
				var name := tok.strip_edges()
				if name != "" and not name.contains("/") and name != "":
					if name.begins_with("`"):
						continue
					out[name] = ch
					in_table = true
	if not in_table:
		_fails.append("★ 通道表解析出来是空的 —— 表被改名/改格式了?(判据会静默空转,故这里响亮报)")
	return out


# 解析产品文件里的声明 → **列表**(★ 用列表不用字典:本仓有**刻意的重名** `beam_fired`,
# 见下方 ③;用字典会把它悄悄合并掉,那正是本仓栽过的那个坑)
func _parse_declarations() -> Array:
	var out: Array = []
	for path in PRODUCT_FILES:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			_fails.append("读不到 %s" % path)
			continue
		var lines := f.get_as_text().split("\n")
		for i in lines.size():
			var l := lines[i].strip_edges()
			if not l.begins_with("@rpc("):
				continue
			var fn := ""
			for k in range(i + 1, mini(i + 8, lines.size())):
				var s := lines[k].strip_edges()
				if s.begins_with("func "):
					fn = s.substr(5).split("(")[0].strip_edges()
					break
			if fn == "":
				continue
			var bits := l.split(",")
			var ch := int(bits[bits.size() - 1].strip_edges().trim_suffix(")"))
			out.append({"fn": fn, "ch": ch, "args": l, "line": i + 1, "file": path.get_file()})
	return out


func _initialize() -> void:
	var table := _parse_table()
	var decl := _parse_declarations()
	var seen := {}
	var dupes := {}
	for d in decl:
		var n: String = d["fn"]
		if seen.has(n):
			dupes[n] = true
		seen[n] = true

	_chk(not table.is_empty(), "通道表必须能解析出条目(%d 条)" % table.size())
	_chk(decl.size() == SCOPE_DECLARATIONS,
			"产品**声明**条数应 = %d(实得 %d;注意数量与「方法名个数 %d」不是一个数)" % [SCOPE_DECLARATIONS, decl.size(), seen.size()])

	# ① 逐条:"声明的通道"必须等于"表里的通道"
	var mism: Array[String] = []
	for d in decl:
		var n: String = d["fn"]
		if not table.has(n):
			mism.append("%s(%s:%d)不在表里" % [n, d["file"], d["line"]])
		elif int(table[n]) != int(d["ch"]):
			mism.append("%s(表 %d / 声明 %d)" % [n, int(table[n]), int(d["ch"])])
	_chk(mism.is_empty(), "声明与通道表不符:%s" % str(mism))
	# ② 反向:表里每个名字至少要有一条声明(防"表过期/函数改名")
	var absent: Array[String] = []
	for n2 in table:
		if not seen.has(n2):
			absent.append("%s(表 %d)" % [n2, int(table[n2])])
	_chk(absent.is_empty(), "表里有、声明里没有(表过期或函数改名):%s" % str(absent))
	# ③ ★ 重名必须是**已知的那一个**:`beam_fired` 在 NetBus 与 NetBusExt 各一份(遗留)。
	#    这条断言的价值 = 让重名**可见并钉住**:新出现一个重名、或 beam_fired 被删掉一份,
	#    都会红,逼人回来看注释里那段"重名 = 接收端挂错 = 静默 no-op"的裁定。
	_chk(dupes.has("beam_fired") and dupes.size() == 1,
			"重名声明集合应恰好 = {beam_fired}(实得 %s)—— 见 netplay.md 通道表一节的说明" % str(dupes.keys()))

	# ④ 四参形态(★ 实测:三参带 int 会被引擎拒)
	var bad_form: Array[String] = []
	for d2 in decl:
		if not str(d2["args"]).contains('"call_remote"'):
			bad_form.append("%s(%s:%d)" % [d2["fn"], d2["file"], d2["line"]])
	_chk(bad_form.is_empty(),
			"每条声明必须是四参形态 `@rpc(mode, \"call_remote\", transfer_mode, 通道)`,以下不是:%s" % str(bad_form))

	if _checks != 6:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED=6 对不上" % _checks)
	print("[rpc-ch] 表 %d 个方法 / 声明 %d 条 / 重名 %s(作用域 %d;测试桩 13 条显式排除)" % [table.size(), decl.size(), str(dupes.keys()), SCOPE_DECLARATIONS])
	if _fails.is_empty():
		print("RPC CHANNEL CONTRACT OK(%d 条断言;★ 代理判据:只证明声明与表一致,不证明分流生效)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("RPC CHANNEL CONTRACT FAILED: %d 处" % _fails.size())
		quit(1)

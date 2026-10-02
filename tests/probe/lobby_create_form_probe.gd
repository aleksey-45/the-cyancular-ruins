extends Node

# 统一大厅 `mp_lobby` 的**创建房间弹层**探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
# 判据: 文本 `LOBBY CREATE FORM PROBE: ALL-OK(10 条断言)`(不看退出码 —— 探针挂住时 --quit-after
#       到期仍 exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ═══ 为什么需要它 ═══
# ★ 弹层"按模式变形"的实现形状**天生静默**:`_apply_create_form` 按 `_form_rows[...]` 取容器
#   置 `visible`,而**键名对不上不报错** —— 表现只是"那一行永远不隐藏"。这类"少登记一个键"的
#   缺陷没有任何运行时信号,只有断言看得见。
# ★ 3v3 关掉禁用武器网格**不是审美**,是真的功能缺陷:那两个勾选框写的是
#   `Settings.pvp_disabled_weapons`(全局),在 3v3 页勾一下会**连带改掉另两个模式**。
#   故相④ 是一条有真实危害的断言,不是"版式检查"。
#
# ★ 不入树实例化(`instantiate()` 后**不** `add_child`):`_ready` 建的顶栏/房卡网格与本任务无关,
#   而入树会顺带触发大厅连接的自动拉取。弹层本体由 `_open_create_dialog()` 手动建。
# ★ `EXPECTED_CHECKS`(见下)是"ALL-OK 不等于全都跑过"那条纪律的落点 —— 出错只会让当前函数
#   当场结束、调用方继续,判词照打。少跑一条即红。
const EXPECTED_CHECKS := 10

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/mp_lobby.tscn")
	# 空载守卫:解析失败时 `load()` 仍返回非 null 但 `instantiate()` 会炸;两者都挡住,
	# 免得走不到 `_finish()` 而让进程挂在 --quit-after 上(一行裁决都不打)。
	if packed == null or not packed.can_instantiate():
		print("LOBBY CREATE FORM PROBE: 无法加载 mp_lobby.tscn")
		get_tree().quit(1)
		return
	# ★ 无类型声明(Variant):本探针按**脚本成员名**访问(`_form_rows` / `_create_payload` …),
	#   声明成 `Control` 会让分析器在编译期报"未知成员"、整份探针加载失败。
	var page = packed.instantiate()
	page._open_create_dialog()

	# ①-⑥:三颗模式按钮各切一次,逐次取四行(`max_players` / `match_time` / `weapons` / `map`)的可见性。
	page._apply_create_form(PvpSession.MODE_ROYALE)
	var royale_max: bool = page._form_rows["max_players"].visible
	var royale_time: bool = page._form_rows["match_time"].visible
	var royale_weapons: bool = page._form_rows["weapons"].visible
	var royale_map: bool = page._form_rows["map"].visible

	page._apply_create_form(PvpSession.MODE_TEAM)
	var team_max: bool = page._form_rows["max_players"].visible
	var team_time: bool = page._form_rows["match_time"].visible
	var team_weapons: bool = page._form_rows["weapons"].visible
	var team_map: bool = page._form_rows["map"].visible

	page._apply_create_form(PvpSession.MODE_PVP)
	var pvp_max: bool = page._form_rows["max_players"].visible
	var pvp_time: bool = page._form_rows["match_time"].visible
	var pvp_weapons: bool = page._form_rows["weapons"].visible
	var pvp_map: bool = page._form_rows["map"].visible

	_check(royale_max and royale_time, "① 大乱斗:人数行 + 限时行都可见")
	_check((not team_max) and (not team_time), "② 3v3:人数行 + 限时行都不可见")
	_check((not pvp_max) and (not pvp_time), "③ 1v1:人数行 + 限时行都不可见")
	# ④ 有真实危害:见文件头 —— 3v3 勾一次禁用武器会改掉另两个模式的 Settings。
	_check(not team_weapons, "④ 3v3:禁用武器网格不可见(不连带改 Settings.pvp_disabled_weapons)")
	_check(pvp_weapons and royale_weapons, "⑤ 1v1 / 大乱斗:禁用武器网格可见")
	_check(pvp_map and royale_map and team_map, "⑥ 三个模式都可见地图选择器")

	_check(_has_close_button(page), "⑦ 弹层里有一颗 × 按钮(文案就是 ×)")

	# ⑧-⑩:三套建房载荷的私有键。
	_check(not page._create_payload(PvpSession.MODE_TEAM).has("disabled_weapons"),
			"⑧ _create_payload(3v3) 不含 disabled_weapons 键")
	var rp: Dictionary = page._create_payload(PvpSession.MODE_ROYALE)
	_check(rp.has("match_time") and typeof(rp["match_time"]) == TYPE_INT,
			"⑨ _create_payload(大乱斗) 含 match_time 且为整数(秒)")
	var pp: Dictionary = page._create_payload(PvpSession.MODE_PVP)
	_check(pp.has("is_public") and pp.has("invite_code"),
			"⑩ _create_payload(1v1) 含 is_public 与 invite_code 键")

	page.free()
	_finish()


# 弹层子树里有没有一颗文案是 `×` 的 Button?(右上角那颗关闭键。)
# ★ 按**子树的任何深度**找:版式若把 × 挪进一层 HBox / 另一容器,断言不该跟着失效;
#   要断的是"有一颗 × 按钮",不是"它在第几层"。
func _has_close_button(page) -> bool:
	var panel: PanelContainer = page._create_panel
	if panel == null:
		return false
	return _find_x(panel)


func _find_x(n: Node) -> bool:
	if n is Button and (n as Button).text == "×":
		return true
	for c in n.get_children():
		if _find_x(c):
			return true
	return false


# ★ 收尾两道:① 断言条数不足 EXPECTED_CHECKS 即红(有断言没跑到);② 有失败即红。
func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY CREATE FORM PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY CREATE FORM PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)

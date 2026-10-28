extends Node

# 【一次性】UI 排版审计取图器(scratch,收尾删除)。一个进程顺序截多张「玩家所见」的 UI 状态图,供人眼查版式。
# 用法(★ 不带 --headless:headless 下视口纹理是空壳,取图静默为空):
#   "<GODOT>" --path . --quit-after 3600 res://audit_shots/ui_audit_shots.tscn -- [流程名 ...]
#   流程名: main settings info beta lobby results level pvp team royale(不给参数 = 前六个轻量流程)
# 输出: res://audit_shots/<名>.png
# ★ 每张图前把上一棵 UI 树整棵摘掉(queue_free):不摘就叠着,图会被上一屏盖住而看不出错。
# ★ 重场景(level/pvp/team/royale)分开进程跑:Level0 全量碰撞析构会偶发原生崩溃,一个进程里连拆两棵不划算。

const OUT := "res://audit_shots/"
const LIGHT := ["main", "settings", "info", "beta", "lobby", "results"]

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("AUDIT: viewport=%s window=%s screen=%s" % [
			str(get_viewport().get_visible_rect().size),
			str(DisplayServer.window_get_size()),
			str(DisplayServer.screen_get_size())])
	var argv := OS.get_cmdline_user_args()
	var want: Array = (LIGHT + ["broadcast", "banner", "wait_host"]).duplicate() if argv.is_empty() else argv
	for n in want:
		var m := "_flow_" + str(n)
		if not has_method(m):
			print("AUDIT: FAIL 无此流程 %s" % str(n))
			_fails += 1
			continue
		print("AUDIT: ==== 流程 %s ====" % str(n))
		await call(m)
		print("AUDIT: ==== 流程 %s 结束 ====" % str(n))
	print("AUDIT: DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


# ── 通用 ──

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# 等秒(create_timer 默认 process_always=true,暂停时也走)
func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _reset() -> void:
	get_tree().paused = false
	NetBus.stop()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await _frames(3)


func _spawn(path: String) -> Node:
	var ps: PackedScene = load(path)
	if ps == null:
		print("AUDIT: FAIL 读不到 %s" % path)
		_fails += 1
		return null
	var n: Node = ps.instantiate()
	if n == null:
		print("AUDIT: FAIL 实例化失败 %s" % path)
		_fails += 1
		return null
	add_child(n)
	return n


func _save(name: String) -> void:
	await _frames(2)
	var vp := get_viewport()
	var tex := vp.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		print("AUDIT: FAIL 取不到视口纹理 %s" % name)
		_fails += 1
		return
	var path := OUT + name + ".png"
	var err := img.save_png(path)
	print("AUDIT: SHOT %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])
	if err != OK:
		_fails += 1


func _find_scroll(n: Node) -> ScrollContainer:
	if n is ScrollContainer:
		return n
	for c in n.get_children():
		var r := _find_scroll(c)
		if r != null:
			return r
	return null


# ── 主菜单 / 单人开局面板 ──

func _flow_main() -> void:
	await _reset()
	var mm := _spawn("res://scenes/main_menu.tscn")
	if mm == null:
		return
	await _wait(1.3)   # 标题 0.1+0.6;按钮最晚 0.45+3*0.09+0.28
	await _save("main_menu")
	mm.call("_on_single_pressed")
	await _wait(0.4)
	await _save("main_sp_panel")


# ── 设置页(上下两段)──

func _flow_settings() -> void:
	await _reset()
	var s := _spawn("res://scenes/settings_menu.tscn")
	if s == null:
		return
	await _wait(0.6)
	await _save("settings_top")
	var sc := _find_scroll(s)
	if sc != null:
		sc.scroll_vertical = 100000
		await _frames(5)
		await _save("settings_bottom")
	else:
		print("AUDIT: settings 无 ScrollContainer,只有一屏")


# ── 信息页(上下两段)──

func _flow_info() -> void:
	await _reset()
	var info := _spawn("res://scenes/info_menu.tscn")
	if info == null:
		return
	await _wait(0.6)
	await _save("info_top")
	var sc := _find_scroll(info)
	if sc != null:
		sc.scroll_vertical = 100000
		await _frames(5)
		await _save("info_bottom")
	else:
		print("AUDIT: info 无 ScrollContainer,只有一屏")


# ── Beta 菜单 ──

func _flow_beta() -> void:
	await _reset()
	var b := _spawn("res://scenes/beta_menu.tscn")
	if b == null:
		return
	await _wait(0.6)
	await _save("beta_menu")


# ── 统一大厅:空列表 / 满房卡 / 三种建房弹层 / 加入弹层 / 三种等待室 ──

func _flow_lobby() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"   # 钉住 ⇒ 状态栏停在「没连上」那一相,图可复现
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.2)
	await _save("lobby_empty")

	# 假房卡:三种模式各两条(未满 + 满房、公开 + 私密、中文名 + 长英文名),验 4 列网格的换行与截断
	var fake := {
		"pvp": [
			{"code": "2468", "is_public": true, "players": 1, "max_players": 2,
					"host": "小明", "map": "res://maps/newfactory.cyrm", "names": ["小明"]},
			{"code": "1357", "is_public": false, "players": 2, "max_players": 2,
					"host": "Anon", "map": "res://maps/demo.cyrm", "names": ["Anon", "小红"]},
		],
		"royale": [
			{"code": "8642", "is_public": true, "players": 3, "max_players": 8,
					"host": "甲", "map": "res://maps/demo.cyrm", "match_time": 300,
					"names": ["甲", "乙", "丙"]},
			{"code": "9753", "is_public": true, "players": 5, "max_players": 6,
					"host": "LongEnglishHostName", "map": "res://maps/newfactory.cyrm",
					"match_time": 600, "names": ["LongEnglishHostName", "乙", "丙", "丁", "戊"]},
		],
		"team": [
			{"code": "1111", "is_public": true, "players": 4, "max_players": 6,
					"host": "队长", "map": "res://maps/newfactory.cyrm",
					"team_counts": {"0": 1, "1": 2, "2": 1},
					"names": ["队长", "乙", "丙", "丁"]},
			{"code": "2222", "is_public": true, "players": 6, "max_players": 6,
					"host": "满房", "map": "res://maps/demo.cyrm",
					"team_counts": {"0": 0, "1": 3, "2": 3},
					"names": ["满房", "乙", "丙", "丁", "戊", "己"]},
		],
	}
	for m in ["pvp", "royale", "team"]:
		lobby.call("_ingest_rooms", m, fake[m])
	await _frames(4)
	await _save("lobby_rooms")

	# 建房弹层:1v1 / 3v3 / 大乱斗三种形态(行显隐不同)
	lobby.call("_open_create_dialog")
	await _frames(4)
	await _save("lobby_create_pvp")
	var cp = lobby.get("_create_dialog")
	if cp != null:
		cp.call("apply", PvpSession.MODE_TEAM)
		await _frames(4)
		await _save("lobby_create_team")
		cp.call("apply", PvpSession.MODE_ROYALE)
		await _frames(4)
		await _save("lobby_create_royale")
		cp.call("set_visible", false)
		await _frames(3)

	# 加入弹层(房号 + 邀请码)
	var rooms = lobby.get("_rooms")
	if rooms != null:
		rooms.call("toggle_join_panel")
		await _frames(4)
		await _save("lobby_join")
		rooms.call("hide_join_panel")
		await _frames(3)

	# 等待室三种形态(直接喂服务器的房间状态形状,与 wait_room.show() 的入口一致)
	var wait = lobby.get("_wait")
	if wait == null:
		print("AUDIT: FAIL 拿不到 _wait")
		_fails += 1
		return
	var pvp_state := {
		"code": "2468", "is_public": true,
		"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"}],
		"your_role": 2, "host_role": 1, "count": 2,
	}
	wait.call("show", pvp_state, PvpSession.MODE_PVP)
	await _frames(4)
	await _save("wait_pvp")

	var royale_state := {
		"code": "8642", "is_public": false, "invite_code": "AB12",
		"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"},
				{"role": 3, "name": "小红"}],
		"your_role": 2, "host_role": 1, "max_players": 4,
	}
	wait.call("show", royale_state, PvpSession.MODE_ROYALE)
	await _frames(4)
	await _save("wait_royale")

	var team_state := {
		"code": "1111", "is_public": true,
		"players": [{"role": 1, "name": "小明", "team": 1},
				{"role": 2, "name": "Anon", "team": 2},
				{"role": 3, "name": "小红", "team": 1},
				{"role": 4, "name": "A_Very_Long_Player_Name", "team": 2},
				{"role": 5, "name": "戊", "team": 0}],
		"your_role": 2, "host_role": 1, "team_size": 3,
	}
	wait.call("show", team_state, PvpSession.MODE_TEAM)
	await _frames(4)
	await _save("wait_team")


# ── 结算页三种模式 ──

func _flow_results() -> void:
	await _reset()
	var mr := _spawn("res://ui/screens/match_result.tscn")
	if mr == null:
		return
	var duel := {
		"stats": {
			1: {"kills": 5, "deaths": 3, "assists": 0, "dealt": 1234, "taken": 987, "acs": 320},
			2: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 987, "taken": 1234, "acs": 210},
		},
		"rounds_won": {1: 2, 2: 1},
		"match_winner": 1,
		"mvp": 1,
	}
	mr.call("show_result", MatchResultPayload.for_duel(duel, {1: "小明", 2: "Anon"}, 1))
	await _frames(4)
	await _save("result_duel")

	var royale := {
		"stats": {
			1: {"kills": 9, "deaths": 2, "dealt": 2100, "taken": 800, "acs": 0},
			2: {"kills": 6, "deaths": 4, "dealt": 1700, "taken": 1100, "acs": 0},
			3: {"kills": 4, "deaths": 5, "dealt": 1200, "taken": 1500, "acs": 0},
			4: {"kills": 2, "deaths": 6, "dealt": 800, "taken": 1900, "acs": 0},
			5: {"kills": 0, "deaths": 7, "dealt": 300, "taken": 2200, "acs": 0},
		},
		"match_winner": 0,
		"mvp": 1,
	}
	mr.call("show_result", MatchResultPayload.for_royale(royale, {
		1: "小明", 2: "Anon", 3: "小红", 4: "A_Very_Long_Player_Name", 5: "戊"}, 1))
	await _frames(4)
	await _save("result_royale")

	var team := {
		"stats": {
			1: {"kills": 9, "deaths": 4, "assists": 3, "dealt": 3000, "taken": 1200, "acs": 260},
			2: {"kills": 7, "deaths": 5, "assists": 5, "dealt": 2500, "taken": 1400, "acs": 230},
			3: {"kills": 5, "deaths": 6, "assists": 7, "dealt": 2000, "taken": 1600, "acs": 200},
			4: {"kills": 8, "deaths": 6, "assists": 2, "dealt": 2700, "taken": 1500, "acs": 240},
			5: {"kills": 4, "deaths": 7, "assists": 6, "dealt": 1800, "taken": 1700, "acs": 190},
			6: {"kills": 2, "deaths": 9, "assists": 1, "dealt": 900, "taken": 2100, "acs": 120},
		},
		"rounds_won": {1: 2, 2: 0},
		"match_winner": 1,
		"mvp": 2,
	}
	mr.call("show_result", MatchResultPayload.for_team(team, {
		1: "小明", 2: "Anon", 3: "小红", 4: "丁", 5: "戊", 6: "A_Very_Long_Player_Name"},
		{1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}, 1))
	await _frames(4)
	await _save("result_team")


# ── 单机对局 HUD + 暂停菜单 ──

func _flow_level() -> void:
	await _reset()
	var lvl := _spawn("res://scenes/level_0.tscn")
	if lvl == null:
		return
	await _wait(1.6)
	await _save("level_hud")
	var pm: Node = PauseMenu.new(false)
	add_child(pm)
	await _frames(3)
	pm.call("open")
	await _frames(5)
	await _save("pause_menu")
	pm.call("close")
	await _frames(3)


# ── 对局内 HUD:1v1 / 3v3 / 大乱斗(真场景 + 喂一条假 round_state 让记分/排行榜有字)──

func _game_common() -> void:
	PvpSession.map_path = "res://maps/newfactory.cyrm"
	PvpSession.spawn = Vector2i(24, 12)
	PvpSession.role = 1
	PvpSession.player_name = "小明"
	PvpSession.beta_mode = false


func _flow_pvp() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/pvp_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var hud = g.find_child("PvpHud", true, false)
	if hud != null:
		hud.call("_on_round_state", {"state": 1, "round": 2, "scores": {1: 3, 2: 4},
				"rounds_won": {1: 1, 2: 0}, "grace": {2: 18.0}})
		if hud.has_method("_on_ping"):
			hud.call("_on_ping", 24)
	await _frames(5)
	await _save("pvp_game")


func _flow_team() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/team_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var hud = g.find_child("TeamHud", true, false)
	if hud != null:
		hud.call("set_my_team", 1)
		hud.call("_on_round_state", {"state": 1, "round": 2, "scores": {1: 5, 2: 6},
				"rounds_won": {1: 1, 2: 0}})
		if hud.has_method("_on_ping"):
			hud.call("_on_ping", 31)
	await _frames(5)
	await _save("team_game")


# ── 中央广播:倒计时 / 本局结束 (1v1 与大乱斗两套形态) ──

func _flow_broadcast() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/pvp_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var hud = g.find_child("PvpHud", true, false)
	if hud == null:
		print("AUDIT: FAIL 拿不到 PvpHud")
		_fails += 1
		return
	hud.call("_on_round_state", {"state": 0, "round": 1, "timer": 3.0,
			"scores": {1: 0, 2: 0}, "rounds_won": {1: 0, 2: 0}, "grace": {}})
	await _wait(0.25)
	await _save("pvp_countdown")
	hud.call("_on_round_state", {"state": 2, "round": 2, "winner": 1,
			"scores": {1: 3, 2: 2}, "rounds_won": {1: 1, 2: 0}, "grace": {}})
	await _frames(6)
	await _save("pvp_round_over")


func _flow_royale_countdown() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/royale_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var hud = g.find_child("RoyaleHud", true, false)
	if hud == null:
		print("AUDIT: FAIL 拿不到 RoyaleHud")
		_fails += 1
		return
	hud.call("_on_round_state", {"state": 0, "timer": 3.0,
			"names": {1: "小明", 2: "Anon"}, "alive": {1: true, 2: true},
			"left": [], "deaths": {1: 0, 2: 0}, "scores": {1: 0, 2: 0}, "grace": {}})
	await _wait(0.25)
	await _save("royale_countdown")


# ── 对局内状态横幅(断线重连)──

func _flow_banner() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/pvp_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var banner = (load("res://ui/hud/status_banner.tscn") as PackedScene).instantiate()
	g.add_child(banner)
	banner.call("set_text", "与服务器断开,正在重连…(第 2 次)")
	await _frames(6)
	await _save("status_banner")


# ── 等待室的房主形态(开始按钮在场)──

func _flow_wait_host() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.0)
	var wait = lobby.get("_wait")
	if wait == null:
		print("AUDIT: FAIL 拿不到 _wait")
		_fails += 1
		return
	wait.call("show", {"code": "2468", "is_public": true,
			"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"}],
			"your_role": 1, "host_role": 1, "count": 2}, PvpSession.MODE_PVP)
	await _frames(4)
	await _save("wait_pvp_host")
	wait.call("show", {"code": "1111", "is_public": true,
			"players": [{"role": 1, "name": "小明", "team": 1},
					{"role": 2, "name": "小红", "team": 1},
					{"role": 3, "name": "甲", "team": 1},
					{"role": 4, "name": "Anon", "team": 2},
					{"role": 5, "name": "乙", "team": 2},
					{"role": 6, "name": "丙", "team": 2}],
			"your_role": 1, "host_role": 1, "team_size": 3}, PvpSession.MODE_TEAM)
	await _frames(4)
	await _save("wait_team_host")


func _flow_royale() -> void:
	await _reset()
	_game_common()
	var g := _spawn("res://scenes/royale_game.tscn")
	if g == null:
		return
	await _wait(1.6)
	var hud = g.find_child("RoyaleHud", true, false)
	if hud != null:
		hud.call("_on_round_state", {"state": 1, "timer": 245.0,
				"names": {1: "小明", 2: "Anon", 3: "小红", 4: "A_Very_Long_Player_Name",
						5: "戊", 6: "己"},
				"alive": {1: true, 2: false, 3: true, 4: true, 5: false, 6: true},
				"left": [],
				"deaths": {1: 1, 2: 3, 3: 2, 4: 0, 5: 4, 6: 1},
				"scores": {1: 6, 2: 3, 3: 4, 4: 7, 5: 1, 6: 2},
				"grace": {6: 42.0}})
		if hud.has_method("_on_ping"):
			hud.call("_on_ping", 18)
	await _frames(5)
	await _save("royale_game")

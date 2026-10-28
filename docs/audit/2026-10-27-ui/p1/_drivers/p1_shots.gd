extends Node

# 【一次性】P1 组件迁移的前后取图夹具（scratch，P1 收尾删除）。
# 用法（★ 不带 --headless：headless 下视口纹理是空壳，取图静默为空）：
#   "<GODOT>" --path . --quit-after 3600 res://audit_shots/p1_shots.tscn -- docs/audit/2026-10-27-ui/p1/phase0/before
# 判定"夹具是否确定"：同一进程外连续跑两次到两个目录，逐像素 diff 必须全 0。
# 固定项：设置里的地图/禁用武器、PvpSession 地址与昵称、大厅状态栏文本、信息页版本号与 commit 列表
# （这两处随 git HEAD 变）、主菜单背景（shader 每帧在动）、LineEdit 光标闪烁（时间相位）。

const OUT_ROOT := "res://docs/audit/2026-10-27-ui/p1/"
const EXPECTED := 14
const CLEAR_BG := Color(0.07, 0.08, 0.10, 1.0)

var _out := ""
var _fails := 0
var _saved := 0
var _log := PackedStringArray()


func _ready() -> void:
	await get_tree().process_frame
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		print("P1SHOT: FAIL 缺参数（输出子目录）")
		get_tree().quit(1)
		return
	var sub := str(argv[0]).trim_prefix("/")
	_out = sub if sub.begins_with("res://") else "res://" + sub
	if not _out.ends_with("/"):
		_out += "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	_pin_global()
	print("P1SHOT: out=%s viewport=%s" % [_out, str(get_viewport().get_visible_rect().size)])
	await _flow_settings()
	await _flow_info()
	await _flow_beta()
	await _flow_main()
	await _flow_lobby()
	await _flow_pause()
	_write_log()
	if _saved != EXPECTED:
		print("P1SHOT: FAIL 张数=%d 期望=%d" % [_saved, EXPECTED])
		_fails += 1
	print("P1SHOT: DONE fails=%d saved=%d" % [_fails, _saved])
	get_tree().quit(0 if _fails == 0 else 1)


# ── 通用 ──

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


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
		print("P1SHOT: FAIL 读不到 %s" % path)
		_fails += 1
		return null
	var n: Node = ps.instantiate()
	if n == null:
		print("P1SHOT: FAIL 实例化失败 %s" % path)
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
		print("P1SHOT: FAIL 取不到视口纹理 %s" % name)
		_fails += 1
		return
	var path := _out + name + ".png"
	var err := img.save_png(path)
	print("P1SHOT: SHOT %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])
	if err != OK:
		_fails += 1
		return
	_saved += 1


func _walk(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out


# 关掉光标闪烁 + 去掉焦点：LineEdit 的光标相位由时间决定，两次跑会差 1~2px。
func _defocus(root: Node) -> void:
	for n in _walk(root):
		if n is LineEdit:
			n.release_focus()
			n.caret_blink = false


func _pin_global() -> void:
	Settings.sp_disabled_weapons.clear()
	Settings.sp_map_path = ""
	Settings.pvp_disabled_weapons.clear()
	PvpSession.player_name = "夹具"
	PvpSession.server_address = "127.0.0.1"
	PvpSession.role = 1
	_log.append("sp_disabled=%s sp_map=%s pvp_disabled=%s addr=%s name=%s" % [
			str(Settings.sp_disabled_weapons), Settings.sp_map_path,
			str(Settings.pvp_disabled_weapons), PvpSession.server_address, PvpSession.player_name])


func _write_log() -> void:
	var f := FileAccess.open(_out + "_fixture.log", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("shots=%d" % _saved)
	for l in _log:
		f.store_line(str(l))
	f.close()


# ── 设置页 ──

func _flow_settings() -> void:
	await _reset()
	var s := _spawn("res://scenes/settings_menu.tscn")
	if s == null:
		return
	await _wait(0.6)
	await _save("settings_top")


# ── 信息页（版本号/commit 列表随 HEAD 变 ⇒ 灌死）──

func _flow_info() -> void:
	await _reset()
	var info := _spawn("res://scenes/info_menu.tscn")
	if info == null:
		return
	await _wait(0.6)
	var v := info.get_node_or_null("%VersionLabel") as Label
	if v != null:
		v.text = "当前版本　夹具"
	var cl := info.get_node_or_null("%CommitList") as VBoxContainer
	if cl == null:
		print("P1SHOT: FAIL 拿不到 %CommitList")
		_fails += 1
		return
	for c in cl.get_children():
		cl.remove_child(c)
		c.queue_free()
	for i in 3:
		cl.add_child(info.call("_commit_row",
				"夹具提交 %d  2026-10-27 00:00  固定行" % (i + 1), UiFactory.C_TEXT))
	await _frames(4)
	await _save("info_top")


# ── Beta ──

func _flow_beta() -> void:
	await _reset()
	var b := _spawn("res://scenes/beta_menu.tscn")
	if b == null:
		return
	await _wait(0.6)
	await _save("beta_menu")


# ── 主菜单：单人开局面板（背景 shader 每帧在动 ⇒ 隐藏 Bg，落到固定清屏色上）──

func _flow_main() -> void:
	await _reset()
	var mm := _spawn("res://scenes/main_menu.tscn")
	if mm == null:
		return
	await _wait(2.0)   # 浮现动画全部结束（最长链 ~1.1s）
	var bg := mm.get_node_or_null("%Bg") as ColorRect
	if bg != null:
		bg.visible = false
		var clear := ColorRect.new()
		clear.color = CLEAR_BG
		clear.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		clear.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mm.get_node("%UIRoot").add_child(clear)
		mm.get_node("%UIRoot").move_child(clear, 0)
	await _frames(3)
	mm.call("_on_single_pressed")
	await _wait(0.6)
	_defocus(mm)
	await _save("main_sp_panel")


# ── 大厅：空列表 / 满房卡 / 三种建房 / 加入 / 三种等待室 ──

func _pin_lobby(lobby: Node) -> void:
	var st = lobby.get("_status")
	if st is Label:
		st.text = "大厅状态栏（夹具固定）"
	_defocus(lobby)


func _flow_lobby() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"   # 无大厅在跑 ⇒ 立刻 connection_failed，状态栏再被夹具灌死
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.2)
	_pin_lobby(lobby)
	await _save("lobby_empty")

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
	_pin_lobby(lobby)
	await _save("lobby_rooms")

	lobby.call("_open_create_dialog")
	await _frames(4)
	_pin_lobby(lobby)
	await _save("lobby_create_pvp")
	var cp = lobby.get("_create_dialog")
	if cp != null:
		cp.call("apply", PvpSession.MODE_TEAM)
		await _frames(4)
		_pin_lobby(lobby)
		await _save("lobby_create_team")
		cp.call("apply", PvpSession.MODE_ROYALE)
		await _frames(4)
		_pin_lobby(lobby)
		await _save("lobby_create_royale")
		cp.call("set_visible", false)
		await _frames(3)

	var rooms = lobby.get("_rooms")
	if rooms != null:
		rooms.call("toggle_join_panel")
		await _frames(4)
		_pin_lobby(lobby)
		await _save("lobby_join")
		rooms.call("hide_join_panel")
		await _frames(3)
	else:
		print("P1SHOT: FAIL 拿不到 _rooms")
		_fails += 1

	var wait = lobby.get("_wait")
	if wait == null:
		print("P1SHOT: FAIL 拿不到 _wait")
		_fails += 1
		return
	var pvp_state := {
		"code": "2468", "is_public": true,
		"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"}],
		"your_role": 2, "host_role": 1, "count": 2,
	}
	wait.call("show", pvp_state, PvpSession.MODE_PVP)
	await _frames(4)
	_pin_lobby(lobby)
	await _save("wait_pvp")

	var royale_state := {
		"code": "8642", "is_public": false, "invite_code": "AB12",
		"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"},
				{"role": 3, "name": "小红"}],
		"your_role": 2, "host_role": 1, "max_players": 4,
	}
	wait.call("show", royale_state, PvpSession.MODE_ROYALE)
	await _frames(4)
	_pin_lobby(lobby)
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
	_pin_lobby(lobby)
	await _save("wait_team")


# ── 暂停菜单：固定在纯色底上（不拉世界，避免随机地图/动画）──

func _flow_pause() -> void:
	await _reset()
	var bg := ColorRect.new()
	bg.color = CLEAR_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	await _frames(2)
	var pm: Node = null
	if ResourceLoader.exists("res://ui/screens/pause_menu.tscn"):
		var ps: PackedScene = load("res://ui/screens/pause_menu.tscn")
		pm = ps.instantiate()
	else:
		pm = PauseMenu.new(false)   # P1 迁移前的旧实现
	add_child(pm)
	await _frames(3)
	pm.call("open")
	await _frames(6)
	await _save("pause_menu")
	pm.call("close")

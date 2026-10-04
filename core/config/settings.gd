extends Node

# 设置中枢(autoload):持久化 + 音频总线 + 键位重映射生效。
# 存储走 ConfigFile(user://settings.cfg);首次运行用 InputMap 现值当默认键位。
# 读写 API 全部带类型;改值后调 save() 落盘。实验分支 KikuchiHeinr 新增。

const SAVE_PATH := "user://settings.cfg"

# 可重映射的动作(1-5 切枪槽固定,不开放重绑)。
const REMAPPABLE_ACTIONS: Array[String] = ["left", "right", "up", "down", "charge", "attack", "R", "F", "Q", "rewind", "haste"]

# ── 音量(0-1 线性)──
var master_volume: float = 0.8:
	set(v):
		master_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("Master", master_volume)
var sfx_volume: float = 1.0:
	set(v):
		sfx_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("SFX", sfx_volume)

# ── 通用 ──
# 鼠标滚轮切枪。★ 2026-09-15 改默认 true:滚轮切枪本就已实现,但默认关着 = 该功能形同虚设
# (用户要求"添加滚轮切武器"时它其实早就在,只是没人开)。已有存档里显式存过 false 的仍读 false。
var wheel_switch: bool = true

# ── 单人开局选项存档(记住上次选择)──
var sp_disabled_weapons: Array[int] = []   # 禁用的武器槽位(1-6;第 6 槽=激光枪)

# 选图(2026-09-26):"" = 随机(= 上游行为:进图时从 res://maps 里现挑一份,会话内固定)。
# 单人/联机各记一条;联机的三个模式(1v1/大乱斗/3v3)共用一条"上次选的图",省得每页各存一份。
var sp_map_path: String = ""
var mp_map_path: String = ""

# ── PvP 选项(本地偏好类直接生效;服务器权威类由房主下发,见 MatchHost)──
var pvp_show_trajectories: bool = true  # 显示敌方武器(子弹)轨迹
var pvp_round_full_heal: bool = false   # 每回合开始回满血(服务器生效项,房主值优先)
var pvp_show_enemy_hp: bool = true      # 显示敌方头顶血条
var pvp_disabled_weapons: Array[int] = []  # 禁用武器(服务器生效项,房主值优先)
var pvp_color_hue: float = 0.0          # 自己角色色相旋转(度;0=默认青色)
var royale_match_min: float = 5.0       # 大乱斗一局限时(分钟,建房页可调,随房主报到生效)
var pvp_show_minimap: bool = true       # 小地图
var pvp_minimap_show_enemy: bool = true # 小地图显示敌方位置

# ── 显示(分辨率档 + 全屏)──
# ★ 四档**全是 4:3** —— 与 project.godot 的 display/window/size/viewport_*(1920×1440)同比例,
#   于是 `stretch/aspect="keep"` 下窗口任意大小时都是**等比缩放、无黑边**(非 4:3 档必有黑边)。
# ★ 这张表是**单一来源**:设置页的下拉读它,`apply_display()` 按它开窗,别再各抄一份尺寸表。
const DEFAULT_DISPLAY_RESOLUTION := Vector2i(1920, 1440)   # 基准 = project.godot 的 viewport 尺寸
const DISPLAY_RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 960),
	Vector2i(1600, 1200),
	Vector2i(1920, 1440),
	Vector2i(2560, 1920),
]

# 分辨率档下标。★ 越界回落写进 setter(与下面 `royale_match_min` 装载时那条 clamp 同一惯例):
#   坏存档 / 手改 cfg / 将来删档位都会喂进非法值,直接拿去索引 DISPLAY_RESOLUTIONS 会越界。
# ★ 默认值由 DEFAULT_DISPLAY_RESOLUTION **反查**而来,不另抄一个字面量下标 —— 抄下标 = 第二个
#   真相源(档位顺序一改,默认档就静默漂走)。
# ★★ 反查**必须写在 `_init()` 里,不能写成成员初始值**:GDScript 的成员初始值**不走 setter**
#   (实测:把档表里的 1920×1440 改掉、`.find()` 得 -1,成员初始值会把 **-1** 原样漏进字段 ⇒
#   窗口化时 `DISPLAY_RESOLUTIONS[-1]` 直接报错)。`_init()` 里的赋值是普通赋值 ⇒ 过 setter ⇒ 压回 0。
var display_res_index: int = 0:
	set(v):
		display_res_index = clampi(v, 0, DISPLAY_RESOLUTIONS.size() - 1)

var display_fullscreen: bool = false

func _init() -> void:
	display_res_index = DISPLAY_RESOLUTIONS.find(DEFAULT_DISPLAY_RESOLUTION)

func _ready() -> void:
	_ensure_buses()
	load_settings()
	apply_display()   # 开窗即用存档里的档位(headless 下 apply_display 自己早退)

# ── 音频总线 ──
# SFX 总线挂在 Master 下;Music 预留给将来 BGM。音量统一 linear→db。
func _ensure_buses() -> void:
	if AudioServer.get_bus_index("Music") == -1:
		var at := AudioServer.bus_count
		AudioServer.add_bus(at)
		AudioServer.set_bus_name(at, "Music")
		AudioServer.set_bus_send(at, "Master")
	if AudioServer.get_bus_index("SFX") == -1:
		var at := AudioServer.bus_count
		AudioServer.add_bus(at)
		AudioServer.set_bus_name(at, "SFX")
		AudioServer.set_bus_send(at, "Master")
	_apply_bus_volume("Master", master_volume)
	_apply_bus_volume("SFX", sfx_volume)

func _apply_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(idx, linear <= 0.001)

# ── 显示:把内存里的档位落到真窗口 ──
# 两个调用方:autoload `_ready()`(开窗即用存档档)、设置页(玩家改完即时生效)。
# ★ headless 早退:无窗口后端(服务器 / `-s` 冒烟)上不该碰窗口 API —— 仓内既有惯例,
#   先例 tests/smoke/menu_autotest.gd:504(`DisplayServer.get_name() == "headless"`)。
# ★ 本函数体内的注释**刻意不写** window_set_size / window_set_mode 这两个字面量:冒烟
#   tests/smoke/settings_display_smoke.gd 的源码半边按"早退必须排在这两个调用之前"判,
#   注释里先出现会把那条判红。
func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# 先摆窗口尺寸、再切模式:窗口化时设下的尺寸会被系统记住,玩家从全屏切回来仍是这一档。
	DisplayServer.window_set_size(DISPLAY_RESOLUTIONS[display_res_index])
	if display_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# ── 键位重映射 ──
# 每动作支持**多个**键位(原作默认:up=W+空格、down=S+Shift),存取都保序完整往返。
# ⚠ 与 set_binding 的组合语义:set_binding 是 erase 后只写一个事件的**单键写入** → 用户
#   主动重绑某动作 = 把该动作改成单键(多键动作如 up = W + Space 会被静默压成单键)。
#   这是本项目键位重绑的设计语义,不是缺陷。要显示一个动作的**全部**键位请用
#   get_binding_names()(逐个遍历);save()/load_settings() 同样遍历全部事件,往返不丢键。

# 显示用:一个动作的全部键位名,如 "W / Space"
func get_binding_names(action: String) -> String:
	var names: Array[String] = []
	for ev in InputMap.action_get_events(action):
		names.append(_event_display_name(ev))
	return " / ".join(names)

func set_binding(action: String, event: InputEvent) -> void:
	if not action in InputMap.get_actions():
		return
	InputMap.action_erase_events(action)
	var ev := event.duplicate()
	ev.pressed = false
	InputMap.action_add_event(action, ev)
	save()

func reset_bindings() -> void:
	InputMap.load_from_project_settings()
	save()

func _event_display_name(ev: InputEvent) -> String:
	if ev is InputEventKey:
		return OS.get_keycode_string((ev as InputEventKey).physical_keycode)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
			MOUSE_BUTTON_WHEEL_UP: return "滚轮上"
			MOUSE_BUTTON_WHEEL_DOWN: return "滚轮下"
			_: return "鼠标键 %d" % (ev as InputEventMouseButton).button_index
	return "?"

# ── 持久化 ──
# ★ 两个函数的 `path` 参数**只为可测**:默认值 = 真存档路径 ⇒ 所有既有调用点行为完全不变;
#   冒烟 tests/smoke/settings_display_smoke.gd 用临时路径验"档位真的落盘 / 真的读回",
#   从而**不必去读写玩家真的 user://settings.cfg**(冒烟不该有"写坏玩家存档"的副作用)。
func save(path: String = SAVE_PATH) -> void:
	var cf := ConfigFile.new()
	cf.set_value("audio", "master_volume", master_volume)
	cf.set_value("audio", "sfx_volume", sfx_volume)
	cf.set_value("controls", "wheel_switch", wheel_switch)
	cf.set_value("single", "disabled_weapons", sp_disabled_weapons)
	cf.set_value("single", "map_path", sp_map_path)
	cf.set_value("pvp", "map_path", mp_map_path)
	cf.set_value("pvp", "show_trajectories", pvp_show_trajectories)
	cf.set_value("pvp", "round_full_heal", pvp_round_full_heal)
	cf.set_value("pvp", "show_enemy_hp", pvp_show_enemy_hp)
	cf.set_value("pvp", "disabled_weapons", pvp_disabled_weapons)
	cf.set_value("pvp", "color_hue", pvp_color_hue)
	cf.set_value("royale", "match_min", royale_match_min)
	cf.set_value("pvp", "show_minimap", pvp_show_minimap)
	cf.set_value("pvp", "minimap_show_enemy", pvp_minimap_show_enemy)
	cf.set_value("display", "res_index", display_res_index)
	cf.set_value("display", "fullscreen", display_fullscreen)
	for action in REMAPPABLE_ACTIONS:
		var arr: Array = []
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				arr.append({"k": (ev as InputEventKey).physical_keycode})
			elif ev is InputEventMouseButton:
				arr.append({"m": (ev as InputEventMouseButton).button_index})
		if not arr.is_empty():
			cf.set_value("bindings", action, arr)
	cf.save(path)

func load_settings(path: String = SAVE_PATH) -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		save(path)   # 首次运行(该路径上没有存档):把当前值(=代码默认)写下去
		return
	master_volume = float(cf.get_value("audio", "master_volume", 0.8))
	sfx_volume = float(cf.get_value("audio", "sfx_volume", 1.0))
	wheel_switch = bool(cf.get_value("controls", "wheel_switch", true))
	sp_disabled_weapons.assign(cf.get_value("single", "disabled_weapons", []))
	sp_map_path = str(cf.get_value("single", "map_path", ""))
	mp_map_path = str(cf.get_value("pvp", "map_path", ""))
	pvp_show_trajectories = bool(cf.get_value("pvp", "show_trajectories", true))
	pvp_round_full_heal = bool(cf.get_value("pvp", "round_full_heal", false))
	pvp_show_enemy_hp = bool(cf.get_value("pvp", "show_enemy_hp", true))
	pvp_disabled_weapons.assign(cf.get_value("pvp", "disabled_weapons", []))
	pvp_color_hue = float(cf.get_value("pvp", "color_hue", 0.0))
	royale_match_min = clampf(float(cf.get_value("royale", "match_min", 5.0)), 1.0, 30.0)
	pvp_show_minimap = bool(cf.get_value("pvp", "show_minimap", true))
	pvp_minimap_show_enemy = bool(cf.get_value("pvp", "minimap_show_enemy", true))
	# 越界值由 `display_res_index` 的 setter 压回合法档(见字段区的注释)。
	display_res_index = int(cf.get_value("display", "res_index",
			DISPLAY_RESOLUTIONS.find(DEFAULT_DISPLAY_RESOLUTION)))
	display_fullscreen = bool(cf.get_value("display", "fullscreen", false))
	for action in REMAPPABLE_ACTIONS:
		# ★ 默认值必须是**真的值**而不是 null:Godot 的 ConfigFile.get_value 把 null 当作
		#   "调用方没给默认值",键不存在时直接报错(Couldn't find ... and no default was given)。
		#   对老存档(在某个动作被加进 REMAPPABLE_ACTIONS 之前写的)来说那个键必然不存在 ——
		#   于是**每加一个新可重绑动作,老玩家启动就刷一屏报错**。空数组语义完全相同
		#   (下面的 is_empty() 分支会跳过),但不会报错。
		# 2026-09-26 用户改令:加速(haste)默认改用**鼠标右键**。旧存档若只存了键盘绑定
		# (Ctrl 时代)一律丢弃并回落到右键;若存的是鼠标绑定则保留(玩家在设置页重绑不受影响)。
		var arr = cf.get_value("bindings", action, [])
		if action == "haste":
			var mouse_only: Array = []
			if arr is Array:
				for item in arr:
					if item is Dictionary and item.has("m"):
						mouse_only.append(item)
			if mouse_only.is_empty():
				InputMap.action_erase_events(action)
				InputMap.action_add_event(action, _make_mouse(MOUSE_BUTTON_RIGHT))
			arr = mouse_only
		# 迁移(2026-09-26):Shift 从 down 改拨给 rewind,老存档里 down 的 Shift 绑定必须摘掉
		if action == "down" and arr is Array:
			var cleaned: Array = []
			for item in arr:
				if item is Dictionary and int(item.get("k", 0)) == KEY_SHIFT:
					continue
				cleaned.append(item)
			arr = cleaned
		if arr is Array and not (arr as Array).is_empty():
			InputMap.action_erase_events(action)
			for item in arr:
				if item is Dictionary:
					if item.has("k"):
						InputMap.action_add_event(action, _make_key(int(item["k"])))
					elif item.has("m"):
						InputMap.action_add_event(action, _make_mouse(int(item["m"])))

func _make_key(keycode: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode as Key
	return ev

func _make_mouse(button: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	return ev

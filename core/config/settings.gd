extends Node


const SAVE_PATH := "user://settings.cfg"
const BINDINGS_VERSION := 1

const REMAPPABLE_ACTIONS: Array[String] = ["left", "right", "up", "down", "attack", "R", "F", "Q", "rewind", "haste"]

var master_volume: float = 0.8:
	set(v):
		master_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("Master", master_volume)
var sfx_volume: float = 1.0:
	set(v):
		sfx_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("SFX", sfx_volume)

var wheel_switch: bool = true

var sp_disabled_weapons: Array[int] = []

var sp_map_path: String = ""
var mp_map_path: String = ""

var pvp_show_trajectories: bool = true
var pvp_round_full_heal: bool = false
var pvp_show_enemy_hp: bool = true
var pvp_disabled_weapons: Array[int] = []
var royale_match_min: float = 5.0
var pvp_show_minimap: bool = true
var pvp_minimap_show_enemy: bool = true

# ★ 六档全是 4:3 —— 与 project.godot 的 viewport(1920×1440)同比例 ⇒ stretch/aspect="keep" 下窗口任意大小时都是等比缩放、无黑边(非 4:3 档必有黑边)。
# ★ 这张表是单一来源:设置页的下拉读它,apply_display() / fit_resolution() 按它开窗,别再各抄一份尺寸表。
# ★ 前两档(1024×768 / 1152×864)是给 1366×768 / 1280×720 这类小屏的:放得下就选能放下的最大档,
#   一档都放不下时 fit_resolution() 会按可用区等比缩成 4:3 —— 绝不把窗口开到屏幕外。
const DEFAULT_DISPLAY_RESOLUTION := Vector2i(1920, 1440)
const DISPLAY_RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1024, 768),
	Vector2i(1152, 864),
	Vector2i(1280, 960),
	Vector2i(1600, 1200),
	Vector2i(1920, 1440),
	Vector2i(2560, 1920),
]

# ★ 旧版持久化表的**历史冻结副本**(旧四档 = 现表去掉最前两个小屏档)。
#   只用于 user://settings.cfg 旧存档迁移(见 _legacy_index_to_res / _res_index_from_config);
#   现役开窗/下拉的真相源仍是 DISPLAY_RESOLUTIONS,**别**把两者混用。
const LEGACY_DISPLAY_RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 960),
	Vector2i(1600, 1200),
	Vector2i(1920, 1440),
	Vector2i(2560, 1920),
]

var display_res_index: int = 0:
	set(v):
		display_res_index = clampi(v, 0, DISPLAY_RESOLUTIONS.size() - 1)

var display_fullscreen: bool = false

func _init() -> void:
	display_res_index = DISPLAY_RESOLUTIONS.find(DEFAULT_DISPLAY_RESOLUTION)

func _ready() -> void:
	_ensure_buses()
	load_settings()
	apply_display()

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

# 选窗口尺寸:优先「能放进可用区的最大 4:3 档」;一档都放不下时按可用区等比缩成 4:3 窗口。
# ★ 返回值的硬约束 = **不超屏**(契约 §5):任何可用区下 r.x <= available.x 且 r.y <= available.y。
# ★ 回退路径整数化到**宽为 4 的倍数** ⇒ 高恰为宽的 3/4,严格 4:3 —— 非 4:3 窗口在 stretch/aspect=keep 下会出黑边,
#   这正是「窗口比可用区还高、被 OS 裁」之外的另一类 UI 不稳来源。
func fit_resolution(available: Vector2i) -> Vector2i:
	# ① 档位优先:能放下的最大 4:3 档(表内全 4:3 ⇒ 按面积取最大等价于取最大宽高)。
	var best := Vector2i.ZERO
	var best_area := 0
	for r in DISPLAY_RESOLUTIONS:
		if r.x <= available.x and r.y <= available.y and r.x * r.y > best_area:
			best = r
			best_area = r.x * r.y
	if best_area > 0:
		return best
	# ② 一档都放不下:宽 = min(可用宽, 可用高*4/3),高 = 宽*3/4;先保不超屏,再整数化。
	var w := mini(available.x, available.y * 4 / 3)
	var h := w * 3 / 4
	if h > available.y:                    # 防御:极端窄屏下按高重算(整数除法的兜底)
		h = available.y
		w = h * 4 / 3
	w -= w % 4                             # 宽取 4 的倍数 ⇒ 高恰为 3/4,严格 4:3
	h = w * 3 / 4
	# ★ 640×480 下限由公式自然成立(可用区 ≥640×480 时,两个候选宽都 ≥640),不需要再夹;
	#   可用区比 640×480 还小时「绝不超屏」优先,只能给更小的窗口。
	return Vector2i(w, h)

func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if OS.has_feature("web"):
		return
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var target := DISPLAY_RESOLUTIONS[display_res_index]
	if target.x > usable.size.x or target.y > usable.size.y:
		target = fit_resolution(usable.size)
	DisplayServer.window_set_size(target)
	DisplayServer.window_set_position(usable.position + (usable.size - target) / 2)
	if display_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# ── 键位重映射 ── 每动作支持多个键位,存取都保序完整往返;默认一律单键(up=空格、down=S)。
# ⚠ set_binding 是 erase 后只写一个事件的单键写入 ⇒ 主动重绑某动作 = 把该动作改成单键(多键动作会被静默压成单键);这是设计语义不是缺陷。

func get_binding_names(action: String) -> String:
	var names: Array[String] = []
	for ev in InputMap.action_get_events(action):
		names.append(_event_display_name(ev))
	return " / ".join(names)

func set_binding(action: String, event: InputEvent, path: String = SAVE_PATH) -> void:
	if not action in InputMap.get_actions():
		return
	InputMap.action_erase_events(action)
	var ev := event.duplicate()
	ev.pressed = false
	# ★ 只留键本身:按住 Ctrl/Shift/Alt 时捕获到的事件自带修饰位,原样存下去会把"K"变成"Ctrl+K"(匹配不上、静默失效)。
	if ev is InputEventKey:
		var key := ev as InputEventKey
		key.shift_pressed = false
		key.ctrl_pressed = false
		key.alt_pressed = false
		key.meta_pressed = false
	InputMap.action_add_event(action, ev)
	save(path)

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

# ── 显示设置持久化:表位移迁移(旧四档表 → 现役六档表)────────────────────────
# 旧版 DISPLAY_RESOLUTIONS 是四档 [1280×960,1600×1200,1920×1440,2560×1920],settings.cfg 存的是**它的下标**;
# 本版在表头插入 1024×768 / 1152×864 ⇒ 同一个数字指向另一档(旧 2 = 1920×1440 → 新 2 = 1280×960)。
# 因此:读档先看新键 display/resolution(Vector2i);没有新键 = 旧存档 ⇒ 旧下标先按**冻结的旧四档表**
# 还原成分辨率、再查现役表。存档同时写新键与旧键(旧键写旧四档表语义,供旧版本读)。
# ★ 返回值恒是现役表 DISPLAY_RESOLUTIONS 的合法下标;解析失败一律回落 DEFAULT_DISPLAY_RESOLUTION。

# 旧四档表下标 → 分辨率;越界/缺失 ⇒ 默认 1920×1440。
func _legacy_index_to_res(old_index: int) -> Vector2i:
	if old_index < 0 or old_index >= LEGACY_DISPLAY_RESOLUTIONS.size():
		return DEFAULT_DISPLAY_RESOLUTION
	return LEGACY_DISPLAY_RESOLUTIONS[old_index]


# 分辨率 → 现役表下标;不在表内 ⇒ -1。
func _res_to_index(res: Vector2i) -> int:
	return DISPLAY_RESOLUTIONS.find(res)


# 现役表分辨率 → 旧四档表可读下标(写旧键用):旧表里有的原样;新小屏档取旧表里最近的可容纳档;
# 比旧表最大档还大 ⇒ 旧表最大档(越界由旧版本自己的 clampi 兜住)。
func _res_to_legacy_index(res: Vector2i) -> int:
	for i in LEGACY_DISPLAY_RESOLUTIONS.size():
		var lr: Vector2i = LEGACY_DISPLAY_RESOLUTIONS[i]
		if lr.x >= res.x and lr.y >= res.y:
			return i
	return LEGACY_DISPLAY_RESOLUTIONS.size() - 1


# 从存档解析 display_res_index(纯函数:冒烟可注入内存 ConfigFile,不碰真文件)。
# 新键存在 ⇒ 它是权威(值不在现役表内时回落默认,不猜);没有新键 ⇒ 按旧四档表映射旧下标。
func _res_index_from_config(cf: ConfigFile) -> int:
	var fallback := _res_to_index(DEFAULT_DISPLAY_RESOLUTION)
	var res_v: Variant = cf.get_value("display", "resolution", "")   # 注意:Godot 的 get_value 默认值不能传 null(会报错)
	if res_v is Vector2i:
		var idx := _res_to_index(res_v)
		return idx if idx >= 0 else fallback
	if not cf.has_section_key("display", "res_index"):
		return fallback
	var old_index := int(cf.get_value("display", "res_index", -1))
	return _res_to_index(_legacy_index_to_res(old_index))


func save(path: String = SAVE_PATH) -> void:
	var cf := ConfigFile.new()
	cf.set_value("audio", "master_volume", master_volume)
	cf.set_value("audio", "sfx_volume", sfx_volume)
	cf.set_value("controls", "wheel_switch", wheel_switch)
	cf.set_value("controls", "bindings_version", BINDINGS_VERSION)
	cf.set_value("single", "disabled_weapons", sp_disabled_weapons)
	cf.set_value("single", "map_path", sp_map_path)
	cf.set_value("pvp", "map_path", mp_map_path)
	cf.set_value("pvp", "show_trajectories", pvp_show_trajectories)
	cf.set_value("pvp", "round_full_heal", pvp_round_full_heal)
	cf.set_value("pvp", "show_enemy_hp", pvp_show_enemy_hp)
	cf.set_value("pvp", "disabled_weapons", pvp_disabled_weapons)
	cf.set_value("royale", "match_min", royale_match_min)
	cf.set_value("pvp", "show_minimap", pvp_show_minimap)
	cf.set_value("pvp", "minimap_show_enemy", pvp_minimap_show_enemy)
	cf.set_value("display", "resolution", DISPLAY_RESOLUTIONS[display_res_index])   # 新键(优先)
	# 旧键保留给旧版本读:写的是**旧四档表**语义的下标(不是新表下标)⇒ 降级后旧版本仍选中同一档/不会炸。
	cf.set_value("display", "res_index", _res_to_legacy_index(DISPLAY_RESOLUTIONS[display_res_index]))
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
		save(path)
		return
	master_volume = float(cf.get_value("audio", "master_volume", 0.8))
	sfx_volume = float(cf.get_value("audio", "sfx_volume", 1.0))
	wheel_switch = bool(cf.get_value("controls", "wheel_switch", true))
	var bind_ver := int(cf.get_value("controls", "bindings_version", 0))
	sp_disabled_weapons.assign(cf.get_value("single", "disabled_weapons", []))
	sp_map_path = str(cf.get_value("single", "map_path", ""))
	mp_map_path = str(cf.get_value("pvp", "map_path", ""))
	pvp_show_trajectories = bool(cf.get_value("pvp", "show_trajectories", true))
	pvp_round_full_heal = bool(cf.get_value("pvp", "round_full_heal", false))
	pvp_show_enemy_hp = bool(cf.get_value("pvp", "show_enemy_hp", true))
	pvp_disabled_weapons.assign(cf.get_value("pvp", "disabled_weapons", []))
	royale_match_min = clampf(float(cf.get_value("royale", "match_min", 5.0)), 1.0, 30.0)
	pvp_show_minimap = bool(cf.get_value("pvp", "show_minimap", true))
	pvp_minimap_show_enemy = bool(cf.get_value("pvp", "minimap_show_enemy", true))
	# 新存档优先 display/resolution;旧存档只有 display/res_index(**旧四档表**下标)⇒ 走历史映射。
	display_res_index = _res_index_from_config(cf)
	display_fullscreen = bool(cf.get_value("display", "fullscreen", false))
	for action in REMAPPABLE_ACTIONS:
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
		if action == "down" and arr is Array:
			var cleaned: Array = []
			for item in arr:
				if item is Dictionary and int(item.get("k", 0)) == KEY_SHIFT:
					continue
				cleaned.append(item)
			arr = cleaned
		if bind_ver < 1 and action == "up":
			arr = [{"k": KEY_SPACE}]
		if arr is Array and not (arr as Array).is_empty():
			InputMap.action_erase_events(action)
			for item in arr:
				if item is Dictionary:
					if item.has("k"):
						InputMap.action_add_event(action, _make_key(int(item["k"])))
					elif item.has("m"):
						InputMap.action_add_event(action, _make_mouse(int(item["m"])))
	if bind_ver < BINDINGS_VERSION:
		save(path)

func _make_key(keycode: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode as Key
	return ev

func _make_mouse(button: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	return ev

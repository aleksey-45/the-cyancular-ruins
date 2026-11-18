extends Node

# 项目以自动加载节点的方式使用这份设置，菜单和各场景均可访问。
# 用户设置读写 user://settings.cfg。项目的 InputMap 提供默认按键。

const SAVE_PATH := "user://settings.cfg"
enum { SECTION, KEY, DEFAULT }
const SCALAR_SETTINGS := {
	&"master_volume": ["audio", "master_volume", 0.8],
	&"sfx_volume": ["audio", "sfx_volume", 1.0],
	&"wheel_switch": ["controls", "wheel_switch", true],
	&"display_fullscreen": ["display", "fullscreen", false],
	&"sp_map_path": ["single", "map_path", ""],
	&"mp_map_path": ["pvp", "map_path", ""],
	&"pvp_show_trajectories": ["pvp", "show_trajectories", true],
	&"pvp_round_full_heal": ["pvp", "round_full_heal", false],
	&"pvp_show_enemy_hp": ["pvp", "show_enemy_hp", true],
	&"pvp_color_hue": ["pvp", "color_hue", 0.0],
	&"royale_match_min": ["royale", "match_min", RoomOptions.DEFAULT_MATCH_MINUTES],
	&"pvp_show_minimap": ["pvp", "show_minimap", true],
	&"pvp_minimap_show_enemy": ["pvp", "minimap_show_enemy", true],
}

# 设置菜单仅列出这些可修改的动作。武器切换固定用数字键 1–4，按背包顺序选择。
const REMAPPABLE_ACTIONS: Array[String] = ["left", "right", "up", "down", "charge", "attack", "R", "F", "Q", "rewind", "haste"]

var master_volume: float = SCALAR_SETTINGS.master_volume[DEFAULT]:
	set(v):
		master_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("Master", master_volume)
var sfx_volume: float = SCALAR_SETTINGS.sfx_volume[DEFAULT]:
	set(v):
		sfx_volume = clampf(v, 0.0, 1.0)
		_apply_bus_volume("SFX", sfx_volume)

var wheel_switch: bool = SCALAR_SETTINGS.wheel_switch[DEFAULT]

var sp_disabled_weapons: Array[int] = []   # 单人模式开局时，从可用武器中排除这些类型。

# 未指定地图路径时，从可用地图中随机挑选。
var sp_map_path: String = SCALAR_SETTINGS.sp_map_path[DEFAULT]
var mp_map_path: String = SCALAR_SETTINGS.mp_map_path[DEFAULT]

var pvp_show_trajectories: bool = SCALAR_SETTINGS.pvp_show_trajectories[DEFAULT]
var pvp_round_full_heal: bool = SCALAR_SETTINGS.pvp_round_full_heal[DEFAULT]
var pvp_show_enemy_hp: bool = SCALAR_SETTINGS.pvp_show_enemy_hp[DEFAULT]
var pvp_disabled_weapons: Array[int] = []  # 多人房间创建时，从可用武器中排除这些类型。
var pvp_color_hue: float = SCALAR_SETTINGS.pvp_color_hue[DEFAULT]
var royale_match_min: float = SCALAR_SETTINGS.royale_match_min[DEFAULT]:
	set(value):
		royale_match_min = clampf(value, RoomOptions.ROYALE_MINUTES.x, RoomOptions.ROYALE_MINUTES.y)
var pvp_show_minimap: bool = SCALAR_SETTINGS.pvp_show_minimap[DEFAULT]
var pvp_minimap_show_enemy: bool = SCALAR_SETTINGS.pvp_minimap_show_enemy[DEFAULT]

# 这些窗口分辨率采用 4:3 的宽高比。游戏画面基于 1920×1440 的视口设置，再缩放至实际窗口大小。
const DISPLAY_RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 960), Vector2i(1600, 1200),
	Vector2i(1920, 1440), Vector2i(2560, 1920),
]
var display_resolution := Vector2i(1920, 1440)
var display_fullscreen: bool = SCALAR_SETTINGS.display_fullscreen[DEFAULT]

func _ready() -> void:
	_ensure_buses()
	load_settings()
	apply_display()


static func fit_window(requested: Vector2i, available: Vector2i) -> Vector2i:
	# 窗口放不进屏幕时，按原来的 4:3 比例缩小。玩家选择的分辨率仍保存在设置中。
	var ratio := minf(1.0, minf(float(available.x) / requested.x, float(available.y) / requested.y))
	var units := maxi(1, int(floor(minf(requested.x / 4.0, requested.y / 3.0) * ratio)))
	return Vector2i(units * 4, units * 3)


func apply_display() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server") \
			or OS.get_cmdline_user_args().has("--server"):
		return
	if display_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	# 先从屏幕可用尺寸扣除给窗口标题栏和边框预留的空间。
	var target := fit_window(display_resolution, Vector2i(maxi(4, usable.size.x - 32), maxi(3, usable.size.y - 64)))
	DisplayServer.window_set_size(target)
	DisplayServer.window_set_position(usable.position + (usable.size - target) / 2)

# 缺少音频总线时新建 SFX 或 Music，并将其输出接到 Master。音量设置换算成分贝后再交给音频服务器。
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


# 界面用斜杠连接同一个动作的多个按键名称，斜杠前后各有一个空格。
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

func store(value: Variant, key: StringName) -> void:
	set(key, value)
	save()

func save() -> void:
	var cf := ConfigFile.new()
	for property: StringName in SCALAR_SETTINGS:
		var field: Array = SCALAR_SETTINGS[property]
		cf.set_value(field[SECTION], field[KEY], get(property))
	cf.set_value("display", "resolution", display_resolution)
	cf.set_value("single", "disabled_weapons", sp_disabled_weapons)
	cf.set_value("pvp", "disabled_weapons", pvp_disabled_weapons)
	for action in REMAPPABLE_ACTIONS:
		var arr: Array = []
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				arr.append({"k": (ev as InputEventKey).physical_keycode})
			elif ev is InputEventMouseButton:
				arr.append({"m": (ev as InputEventMouseButton).button_index})
		if not arr.is_empty():
			cf.set_value("bindings", action, arr)
	cf.save(SAVE_PATH)

func load_settings() -> void:
	var cf := ConfigFile.new()
	var error := cf.load(SAVE_PATH)
	if error != OK:
		if error == ERR_FILE_NOT_FOUND:
			save()
		return
	for property: StringName in SCALAR_SETTINGS:
		var field: Array = SCALAR_SETTINGS[property]
		var value: Variant = cf.get_value(field[SECTION], field[KEY], field[DEFAULT])
		match typeof(field[DEFAULT]):
			TYPE_BOOL: set(property, bool(value))
			TYPE_FLOAT: set(property, float(value))
			TYPE_STRING: set(property, str(value))
	var saved_resolution = cf.get_value("display", "resolution", display_resolution)
	if saved_resolution is Vector2i and saved_resolution in DISPLAY_RESOLUTIONS:
		display_resolution = saved_resolution
	sp_disabled_weapons.assign(cf.get_value("single", "disabled_weapons", []))
	pvp_disabled_weapons.assign(cf.get_value("pvp", "disabled_weapons", []))
	for action in REMAPPABLE_ACTIONS:
		var saved: Variant = cf.get_value("bindings", action, [])
		if not saved is Array:
			continue
		var events: Array[InputEvent] = []
		for item in saved:
			if not item is Dictionary:
				continue
			var key: Variant = item.get("k")
			var mouse: Variant = item.get("m")
			if key is int and key > 0:
				events.append(_make_key(key))
			elif mouse is int and mouse > 0:
				events.append(_make_mouse(mouse))
		if not events.is_empty():
			InputMap.action_erase_events(action)
			for event in events:
				InputMap.action_add_event(action, event)

func _make_key(keycode: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode as Key
	return ev

func _make_mouse(button: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	return ev

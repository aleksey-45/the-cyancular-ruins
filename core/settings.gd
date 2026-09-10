extends Node

# 设置中枢(autoload):持久化 + 音频总线 + 键位重映射生效。
# 存储走 ConfigFile(user://settings.cfg);首次运行用 InputMap 现值当默认键位。
# 读写 API 全部带类型;改值后调 save() 落盘。实验分支 KikuchiHeinr 新增。

const SAVE_PATH := "user://settings.cfg"

# 可重映射的动作(1-5 切枪槽固定,不开放重绑)。
const REMAPPABLE_ACTIONS: Array[String] = ["left", "right", "up", "down", "charge", "attack", "R"]

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
var wheel_switch: bool = false    # 鼠标滚轮切枪
var reload_enabled: bool = true   # 换弹装填(实验性;关闭=旧版无限弹;仅单机生效)

# ── 单人开局选项存档(记住上次选择)──
var sp_disabled_weapons: Array[int] = []   # 禁用的武器槽位(1-6;第 6 槽=激光枪)

# ── PvP 选项(本地偏好类直接生效;服务器权威类由房主下发,见 MatchHost)──
var pvp_show_trajectories: bool = true  # 显示敌方武器(子弹)轨迹
var pvp_round_full_heal: bool = false   # 每回合开始回满血(服务器生效项,房主值优先)
var pvp_show_enemy_hp: bool = true      # 显示敌方头顶血条
var pvp_disabled_weapons: Array[int] = []  # 禁用武器(服务器生效项,房主值优先)
var pvp_color_hue: float = 0.0          # 自己角色色相旋转(度;0=默认青色)
var royale_match_min: float = 5.0       # 大乱斗一局限时(分钟,建房页可调,随房主报到生效)
var pvp_show_minimap: bool = true       # 小地图
var pvp_minimap_show_enemy: bool = true # 小地图显示敌方位置

func _ready() -> void:
	_ensure_buses()
	load_settings()

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

# ── 键位重映射 ──
# 每动作支持**多个**键位(原作默认:up=W+空格、down=S+Shift),存取都保序完整往返。
func get_binding(action: String) -> InputEvent:
	var evs := InputMap.action_get_events(action)
	return evs[0] if evs.size() > 0 else null

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
func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("audio", "master_volume", master_volume)
	cf.set_value("audio", "sfx_volume", sfx_volume)
	cf.set_value("controls", "wheel_switch", wheel_switch)
	cf.set_value("gameplay", "reload_enabled", reload_enabled)
	cf.set_value("single", "disabled_weapons", sp_disabled_weapons)
	cf.set_value("pvp", "show_trajectories", pvp_show_trajectories)
	cf.set_value("pvp", "round_full_heal", pvp_round_full_heal)
	cf.set_value("pvp", "show_enemy_hp", pvp_show_enemy_hp)
	cf.set_value("pvp", "disabled_weapons", pvp_disabled_weapons)
	cf.set_value("pvp", "color_hue", pvp_color_hue)
	cf.set_value("royale", "match_min", royale_match_min)
	cf.set_value("pvp", "show_minimap", pvp_show_minimap)
	cf.set_value("pvp", "minimap_show_enemy", pvp_minimap_show_enemy)
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
	if cf.load(SAVE_PATH) != OK:
		save()   # 首次运行:把当前值(=代码默认)写下去
		return
	master_volume = float(cf.get_value("audio", "master_volume", 0.8))
	sfx_volume = float(cf.get_value("audio", "sfx_volume", 1.0))
	wheel_switch = bool(cf.get_value("controls", "wheel_switch", false))
	reload_enabled = bool(cf.get_value("gameplay", "reload_enabled", true))
	sp_disabled_weapons.assign(cf.get_value("single", "disabled_weapons", []))
	pvp_show_trajectories = bool(cf.get_value("pvp", "show_trajectories", true))
	pvp_round_full_heal = bool(cf.get_value("pvp", "round_full_heal", false))
	pvp_show_enemy_hp = bool(cf.get_value("pvp", "show_enemy_hp", true))
	pvp_disabled_weapons.assign(cf.get_value("pvp", "disabled_weapons", []))
	pvp_color_hue = float(cf.get_value("pvp", "color_hue", 0.0))
	royale_match_min = clampf(float(cf.get_value("royale", "match_min", 5.0)), 1.0, 30.0)
	pvp_show_minimap = bool(cf.get_value("pvp", "show_minimap", true))
	pvp_minimap_show_enemy = bool(cf.get_value("pvp", "minimap_show_enemy", true))
	for action in REMAPPABLE_ACTIONS:
		var arr = cf.get_value("bindings", action, null)
		if arr is Array and not (arr as Array).is_empty():
			InputMap.action_erase_events(action)
			for item in arr:
				if item is Dictionary:
					if item.has("k"):
						InputMap.action_add_event(action, _make_key(int(item["k"])))
					elif item.has("m"):
						InputMap.action_add_event(action, _make_mouse(int(item["m"])))

func _apply_binding(action: String, ev: InputEvent) -> void:
	if ev == null or not action in InputMap.get_actions():
		return
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)

func _make_key(keycode: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode as Key
	return ev

func _make_mouse(button: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	return ev

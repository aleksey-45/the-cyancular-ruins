class_name CombatFeedback
extends CanvasLayer

# 打击反馈层(KH-hit-feedback 分支):屏幕中心 FPS 式命中 X 标记 +「击杀 XXX」像素播报。
# 受击侧的微红/震屏在 PostProcess.flash_hit + 相机 shake(见 combat_component.take_hit),不在此层。
# 实例由各对局场景挂载(单机 Level0 / pvp_client / royale_game);静态入口在无实例时
# (服务器 headless 进程/主菜单)静默空操作,调用方(子弹/爆炸/敌死)无需判空。

const LAYER := 131        # PostProcess(128) < 单机 HUD(129) < PvpHud/RoyaleHud(130) 之上
const HIT_LIFE := 0.22    # X 标记存活时长(秒)
const KILL_FADE_IN := 0.08
const KILL_HOLD := 0.9    # 击杀文字停留时长(秒)
const KILL_FADE_OUT := 0.35
const STREAK_RESET := 6.0 # 连杀窗口:隔此秒数没有新击杀则连杀清零(秒)
const ATTRIB_WINDOW_MS := 3000 # 归因时效:距最后一次受击超过此毫秒数的死亡不再归因给该射手
const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"

# 敌人显示名对照(键 = 场景名去掉 Enemy 前缀,即 enemies.json 的 name 字段)
const ENEMY_NAMES := {"FlyBird": "飞鸟", "JumpBird": "跳鸟", "BlackBird": "黑影"}

static var current: CombatFeedback = null   # 当前对局的反馈层;null = 非对局/服务器,静态入口空转


## 由对局场景挂载(重复调用安全;换局由 _exit_tree 自清)
## 幂等判据不能只看 current 是否存在:换场时(safe_change_scene 先 add_child 新场景、后 remove_child 旧世界)
## 旧实例仍在树上且仍是 current,只看存在性会让新世界提前 return → 反馈层静默消失。
## 故须满足「current 有效 **且** 已是本 host 的后代」才幂等返回。
static func spawn(host: Node) -> void:
	if current != null and is_instance_valid(current) and host.is_ancestor_of(current):
		return
	var fx := CombatFeedback.new()
	host.add_child.call_deferred(fx)


## 命中反馈:屏幕中心 X 标记(玩家子弹/爆炸命中实体时调用)
static func hit_marker() -> void:
	if current != null:
		current._show_hit()


## 击杀播报:屏幕中心「击杀 XXX」+ 音效(who = 被击杀者显示名);内部维护连杀计数
## (STREAK_RESET 秒内有新击杀则 +1,否则清零重计),同时闪现像素骷髅头 + 连杀数。
static func kill(who: String) -> void:
	if current != null:
		current._show_kill(who)


## 自己被击杀时连杀清零(PvP 客户端在 kill_event victim==自己 时调用;单机仅按时间窗清零)
static func reset_streak() -> void:
	if current != null:
		current._streak = 0
		current._last_kill_ms = -1


## EnemyBase._begin_death 调用:仅「玩家造成的死亡」才播报——读受害者 last_damager meta,
## 溺水/环境死(无射手)安静销毁,不再全局播 kill 音效。
static func notify_enemy_killed(victim: Node) -> void:
	if current == null or not victim.has_meta("last_damager"):
		return
	var killer: Node = victim.get_meta("last_damager")
	if killer == null or not is_instance_valid(killer) or not killer.is_in_group("player"):
		return
	# 归因时效:太久以前打过的伤害不再算这回的击杀(否则"蹭过一下、后溺水"也会播报)
	if not victim.has_meta("last_damager_time"):
		return
	# 边界取 >=:窗口边界本身即视为过期(同帧写入-读取的差值为 0,用 > 会让时效"永远不过期",
	# 常量取 0 时也永不为真 → 不可反证)
	if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) >= ATTRIB_WINDOW_MS:
		return
	kill(enemy_display_name(victim))


## 敌人显示名:场景文件名去 Enemy 前缀/.tscn 后查表,查不到回落原名
static func enemy_display_name(victim: Node) -> String:
	var base := String(victim.scene_file_path).get_file().trim_suffix(".tscn").trim_prefix("Enemy")
	return ENEMY_NAMES.get(base, base)


var _marker: HitMarker = null
var _kill_label: RichTextLabel = null
var _skull: KillSkull = null       # 击杀像素骷髅(与击杀播报同窗闪现)
var _streak_label: Label = null    # 连杀数("x3",骷髅右侧)
var _streak := 0                   # 当前连杀数
var _last_kill_ms := -1            # 上次击杀时刻(连杀窗口判定;-1=无)
var _hit_age := -1.0    # <0 = 隐藏
var _kill_age := -1.0


func _ready() -> void:
	layer = LAYER
	current = self
	process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停时动画也能收尾
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	# 命中 X:铺满全屏的自绘控件,画在正中心
	_marker = HitMarker.new()
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	root.add_child(_marker)
	# 击杀播报:全屏富文本居中,大标题同款像素风——青色「击杀」+ 金色被击杀者名,
	# 粗黑描边;固定条带位于屏幕中心上方,避开正中心的 X 标记
	_kill_label = RichTextLabel.new()
	_kill_label.bbcode_enabled = true
	_kill_label.scroll_active = false
	_kill_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_kill_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_kill_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_kill_label.offset_left = -600
	_kill_label.offset_right = 600
	_kill_label.offset_top = -166
	_kill_label.offset_bottom = -66
	_kill_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_kill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_kill_label.add_theme_font_override("normal_font", load(PIXEL_FONT))
	_kill_label.add_theme_font_override("bold_font", load(PIXEL_FONT))
	_kill_label.add_theme_font_size_override("normal_font_size", 68)
	_kill_label.add_theme_font_size_override("bold_font_size", 68)
	_kill_label.add_theme_color_override("default_color", Color(0.55, 0.95, 1.0))   # 标题青
	_kill_label.add_theme_constant_override("outline_size", 16)
	_kill_label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.95))
	_kill_label.modulate.a = 0.0
	root.add_child(_kill_label)
	# 击杀骷髅:屏幕正中央的像素骷髅头(8×8 像素画 ×8 放大),随击杀播报同窗闪现
	_skull = KillSkull.new()
	_skull.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_skull.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_skull.grow_vertical = Control.GROW_DIRECTION_BOTH
	_skull.offset_left = -40
	_skull.offset_right = 40
	_skull.offset_top = -40
	_skull.offset_bottom = 40
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.visible = false
	root.add_child(_skull)
	# 连杀数:骷髅右侧的金色像素数字
	_streak_label = Label.new()
	_streak_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_streak_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_streak_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_streak_label.offset_left = 44
	_streak_label.offset_right = 300
	_streak_label.offset_top = -24
	_streak_label.offset_bottom = 24
	_streak_label.text = ""
	_streak_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_streak_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_streak_label.add_theme_font_override("font", load(PIXEL_FONT))
	_streak_label.add_theme_font_size_override("font_size", 44)
	_streak_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.43))
	_streak_label.add_theme_constant_override("outline_size", 10)
	_streak_label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.95))
	_streak_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_streak_label.modulate.a = 0.0
	root.add_child(_streak_label)


func _exit_tree() -> void:
	if current == self:
		current = null


func _show_hit() -> void:
	_hit_age = 0.0
	_marker.t = 0.0
	_marker.visible = true
	_marker.queue_redraw()


func _show_kill(who: String) -> void:
	# 连杀计数:STREAK_RESET 窗口内续杀 +1,超窗清零重计
	var now := Time.get_ticks_msec()
	if _last_kill_ms < 0 or now - _last_kill_ms > int(STREAK_RESET * 1000.0):
		_streak = 0
	_last_kill_ms = now
	_streak += 1
	# 击杀名里的 "[" 去掉,防止用户昵称拼进 BBCode
	_kill_label.text = "击杀 [color=#ffd76e]%s[/color]" % who.replace("[", "")
	_skull.visible = true
	_streak_label.text = "x%d" % _streak
	_kill_age = 0.0
	Sfx.play("kill")


func _process(delta: float) -> void:
	if _hit_age >= 0.0:
		_hit_age += delta
		_marker.t = clampf(_hit_age / HIT_LIFE, 0.0, 1.0)
		_marker.queue_redraw()
		if _hit_age >= HIT_LIFE:
			_hit_age = -1.0
			_marker.visible = false
	if _kill_age >= 0.0:
		_kill_age += delta
		var a := 1.0
		if _kill_age < KILL_FADE_IN:
			a = _kill_age / KILL_FADE_IN   # 快速浮现
		elif _kill_age > KILL_HOLD:
			a = maxf(1.0 - (_kill_age - KILL_HOLD) / KILL_FADE_OUT, 0.0)
		_kill_label.modulate.a = a
		# 开局轻微回落 pop(围绕文字中心;全屏 rect 的 pivot 取屏幕中心即可)
		_kill_label.pivot_offset = _kill_label.size * 0.5
		var s := 1.0 + 0.22 * maxf(1.0 - _kill_age / 0.14, 0.0)
		_kill_label.scale = Vector2(s, s)
		# 骷髅 + 连杀数随击杀播报同窗淡入淡出 / pop(各围绕自身中心)
		for fx: Control in [_skull, _streak_label]:
			fx.modulate.a = a
			fx.pivot_offset = fx.size * 0.5
			fx.scale = Vector2(s, s)
		if _kill_age >= KILL_HOLD + KILL_FADE_OUT:
			_kill_age = -1.0
			_kill_label.modulate.a = 0.0
			for fx: Control in [_skull, _streak_label]:
				fx.modulate.a = 0.0
				fx.visible = false


# 命中 X 标记:四段斜线(中心留缺口),生命周期内缺口外扩 + 线段微收 + 淡出;
# 白芯 + 深色描边,任意背景下可见。
class HitMarker extends Control:
	var t := 0.0   # 0..1

	func _draw() -> void:
		var c := size * 0.5
		var gap := 6.0 + 5.0 * t
		var seg := 10.0 - 3.0 * t
		var a := 1.0 - t
		for u in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var d: Vector2 = (u as Vector2).normalized()
			var p0: Vector2 = c + d * gap
			var p1: Vector2 = c + d * (gap + seg)
			draw_line(p0, p1, Color(0.05, 0.05, 0.05, a * 0.9), 6.0)
			draw_line(p0, p1, Color(1, 1, 1, a), 3.0)


# 击杀骷髅:8×8 像素画(' #'骨白 / 'o'暗部)逐格绘制,深色描边垫底;纯视觉,随播报同窗显隐。
class KillSkull extends Control:
	const PX := 8.0
	const BONE := Color(0.96, 0.96, 0.92)
	const DARK := Color(0.07, 0.08, 0.11)
	const PIX := [
		"..####..",
		".######.",
		".######.",
		".#o##o#.",
		".######.",
		"..####..",
		"..####..",
		"..o##o..",
	]

	func _draw() -> void:
		var w := float(PIX[0].length()) * PX
		var h := float(PIX.size()) * PX
		var origin := (size - Vector2(w, h)) * 0.5
		for yy in range(PIX.size()):
			var row: String = PIX[yy]
			for xx in range(row.length()):
				var ch := row[xx]
				if ch == ".":
					continue
				var r := Rect2(origin + Vector2(float(xx) * PX, float(yy) * PX), Vector2(PX, PX))
				if ch == "#":
					# 深色描边垫底(外扩 1px,拼出像素风轮廓)
					draw_rect(Rect2(r.position - Vector2(1, 1), r.size + Vector2(2, 2)), DARK)
					draw_rect(r, BONE)
				else:
					draw_rect(r, DARK)

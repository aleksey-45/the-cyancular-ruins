class_name CombatFeedback
extends CanvasLayer

# 战斗打击反馈层：
# 提供准星中心命中标记（X 形）与击杀播报动效。
# 挂载于对局场景中，静态方法在无实例时安全静默返回。

const LAYER := 131
const HIT_LIFE := 0.22    # 命中标记留存时间（秒）
const KILL_FADE_IN := 0.08
const KILL_HOLD := 0.9    # 击杀信息展示停留时间（秒）
const KILL_FADE_OUT := 0.35
const STREAK_RESET := 6.0 # 连杀重置超时窗口（秒）
const ATTRIB_WINDOW_MS := 3000 # 击杀归因时效窗口（毫秒）

static var current: CombatFeedback = null


## 实例化并挂载至对局节点
static func spawn(host: Node) -> void:
	if current != null and is_instance_valid(current) and host.is_ancestor_of(current):
		return
	var fx: CombatFeedback = load("res://ui/hud/combat_feedback.tscn").instantiate() as CombatFeedback
	host.add_child.call_deferred(fx)


## 触发屏幕中心命中标记动效
static func hit_marker() -> void:
	if current != null:
		current._show_hit()


## 触发击杀提示与音效播报
static func kill(who: String) -> void:
	if current != null:
		current._show_kill(who)


## 本地角色阵亡时重置连杀计数
static func reset_streak() -> void:
	if current != null:
		current._streak = 0
		current._last_kill_ms = -1


## 记录击杀归因数据（写入攻击者元数据与命中时间戳）
static func attribute(victim: Node, attacker: Node) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	if attacker == null or not is_instance_valid(attacker) or attacker == victim:
		return
	victim.set_meta("last_damager", attacker)
	victim.set_meta("last_damager_time", Time.get_ticks_msec())
	victim.remove_meta("last_self_hit_time")


## 记录爆炸等造成的自伤标记时间戳
static func note_self_hit(victim: Node) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	victim.set_meta("last_self_hit_time", Time.get_ticks_msec())


## 检查实体近期窗口内是否存在自伤判定
static func is_fresh_self_hit(victim: Node, window_ms: int) -> bool:
	if victim == null or not is_instance_valid(victim):
		return false
	if not victim.has_meta("last_self_hit_time"):
		return false
	return Time.get_ticks_msec() - int(victim.get_meta("last_self_hit_time")) <= window_ms


## 统一执行伤害归因并播放命中反馈动效
static func attribute_hit(victim: Node, attacker: Node) -> void:
	attribute(victim, attacker)
	hit_marker()


var _marker: HitMarker = null
var _skull: KillSkull = null
var _streak := 0
var _last_kill_ms := -1
var _hit_age := -1.0
var _kill_age := -1.0

@onready var _kill_label: RichTextLabel = $Root/KillLabel
@onready var _streak_label: Label = $Root/StreakLabel


func _ready() -> void:
	layer = LAYER
	current = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	PixelFont.shared()
	_marker = HitMarker.new()
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	$Root/HitMarkerSlot.add_child(_marker)
	_skull = KillSkull.new()
	_skull.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.visible = false
	$Root/SkullSlot.add_child(_skull)


func _exit_tree() -> void:
	if current == self:
		current = null


func _show_hit() -> void:
	_hit_age = 0.0
	_marker.t = 0.0
	_marker.visible = true
	_marker.queue_redraw()


func _show_kill(who: String) -> void:
	var now := Time.get_ticks_msec()
	if _last_kill_ms < 0 or now - _last_kill_ms > int(STREAK_RESET * 1000.0):
		_streak = 0
	_last_kill_ms = now
	_streak += 1
	# 过滤昵称中的括号符号以防干扰富文本标签
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
			a = _kill_age / KILL_FADE_IN
		elif _kill_age > KILL_HOLD:
			a = maxf(1.0 - (_kill_age - KILL_HOLD) / KILL_FADE_OUT, 0.0)
		_kill_label.modulate.a = a
		_kill_label.pivot_offset = _kill_label.size * 0.5
		var s := 1.0 + 0.22 * maxf(1.0 - _kill_age / 0.14, 0.0)
		_kill_label.scale = Vector2(s, s)
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


# 屏幕中心命中标记自定义绘制控件
class HitMarker extends Control:
	var t := 0.0

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


# 像素风骷髅图标自定义绘制控件
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
					draw_rect(Rect2(r.position - Vector2(1, 1), r.size + Vector2(2, 2)), DARK)
					draw_rect(r, BONE)
				else:
					draw_rect(r, DARK)


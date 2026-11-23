class_name CombatFeedback
extends CanvasLayer

# 击打/击杀反馈(命中准星 + 击杀播报 + 连杀计数)。UI-3b 迁移到设计系统 v2。
#
# ── 与 main 参考版的关系 ────────────────────────────────────────────────────
# 结构照 main 的 ui/hud/combat_feedback:Root(全屏 Control)内
#   HitMarker(全屏自绘准星)/ KillLabel(RichTextLabel)/ SkullSlot(自绘骷髅)/ StreakLabel;
# 不同处:siri 把节点在 _ready 里就地搭出来(宿主 match_view.tscn 直接用脚本挂 CanvasLayer,
# 不需要新 .tscn,也不新增集成点)。
#
# ── siri 契约(与迁移前逐项一致)──────────────────────────────────────────────
#   · show_hit() / reset_streak() / show_kill(who) 三个公开入口不变;
#   · HIT_LIFE / KILL_LIFE / STREAK_RESET 与 _now / 各计时变量的语义不变
#     (tests/simulation_case.gd 读 feedback._now,不能让时钟停摆);
#   · 准星在屏幕正中扩散淡出、骷髅逐像素绘制、连杀计数、击杀音效 Sfx.play("kill") 均保持;
#   · 布局改为容器(居中 VBox:击杀字在上,骷髅 + 连杀在下),不再写相对坐标偏移。
#
# ── v2 约束 ────────────────────────────────────────────────────────────────
# 颜色只取 UiDesign 调色板 token;字体取 UiDesign.pixel_font();字号用 T_* token 组合。
# 自绘(准星/骷髅)只允许出现几何像素常量,不出现颜色字面量。

const HIT_LIFE := 0.22
const KILL_LIFE := 1.25
const STREAK_RESET := 6.0

# 骷髅像素图(8×8,每格 8px):"#" = 骨白,"o" = 眼/鼻暗块,"." = 透明。
const SKULL := [
	"..####..",
	".######.",
	".######.",
	".#o##o#.",
	".######.",
	"..####..",
	"..####..",
	"..o##o..",
]
const SKULL_PX := 8.0

# 准星 4 条斜线的几何(像素):长度随命中进度收缩、离中心距离扩散。
const HIT_GAP := 6.0
const HIT_SPREAD := 5.0
const HIT_SEG := 10.0
const HIT_SEG_SHRINK := 3.0
const HIT_OUTLINE_W := 6.0
const HIT_CORE_W := 3.0

# 字号:击杀播报 64、连杀 48(16 的倍数;用 token 组合,与迁移前同尺寸)。
const KILL_FONT := UiDesign.T_H2 * 2   # 64
const STREAK_FONT := UiDesign.T_H1     # 48

const KILL_OUTLINE := UiDesign.SP_4    # 16
const STREAK_OUTLINE := UiDesign.SP_3  # 12(原 10,统到间距 token 档)

var _root: Control
var _marker := Control.new()
var _kill_label := RichTextLabel.new()
var _streak_label: Label
var _skull := Control.new()
var _now := 0.0
var _hit_at := -HIT_LIFE
var _kill_at := -STREAK_RESET
var _streak := 0
var _hit_progress := 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 131

	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_marker.name = "HitMarker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.draw.connect(_draw_hit)
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.hide()
	_root.add_child(_marker)

	# 居中容器:击杀字 + (骷髅 + 连杀) 两层,全部由内容撑开。
	# 整组上移 SP_9(64px):让击杀字落在屏幕中心上方(与 main 参考版 −166..−66 的观感一致),
	# 而不是正好压住准星中心;偏移是锚点相对值(HUD 例外),不是绝对坐标。
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_top = -UiDesign.SP_9
	center.offset_bottom = -UiDesign.SP_9
	_root.add_child(center)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", UiDesign.SP_5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	_kill_label.name = "KillLabel"
	_kill_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_label.bbcode_enabled = true
	_kill_label.scroll_active = false
	_kill_label.fit_content = true
	_kill_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_kill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_kill_label.add_theme_color_override("default_color", UiDesign.C_ACCENT)
	_kill_label.add_theme_color_override("font_outline_color", UiDesign.C_BG)
	_kill_label.add_theme_constant_override("outline_size", KILL_OUTLINE)
	var font := UiDesign.pixel_font()
	if font != null:
		for face in ["normal", "bold"]:
			_kill_label.add_theme_font_override(face + "_font", font)
			_kill_label.add_theme_font_size_override(face + "_font_size", KILL_FONT)
	_kill_label.modulate.a = 0.0
	column.add_child(_kill_label)

	# 骷髅 + 连杀:同一行紧密相邻(间距 SP_1 = 原 4px)。
	var row := HBoxContainer.new()
	row.name = "KillRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiDesign.SP_1)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	_skull.name = "SkullSlot"
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.custom_minimum_size = Vector2(UiDesign.SP_10, UiDesign.SP_10)
	_skull.draw.connect(_draw_skull)
	_skull.hide()
	row.add_child(_skull)

	_streak_label = UiDesign.label("", STREAK_FONT, UiDesign.C_GOLD)
	_streak_label.name = "StreakLabel"
	_streak_label.add_theme_color_override("font_outline_color", UiDesign.C_BG)
	_streak_label.add_theme_constant_override("outline_size", STREAK_OUTLINE)
	_streak_label.modulate.a = 0.0
	row.add_child(_streak_label)


func show_hit() -> void:
	_hit_at = _now


func reset_streak() -> void:
	_streak = 0


func show_kill(who: String) -> void:
	_streak = 1 if _now - _kill_at > STREAK_RESET else _streak + 1
	_kill_at = _now
	# 昵称里的 "[" 会把 BBCode 打断,先去掉;高亮色取调色板的金色 token。
	_kill_label.text = "击杀 [color=#%s]%s[/color]" % [
			UiDesign.C_GOLD.to_html(false), who.replace("[", "")]
	_streak_label.text = "x%d" % _streak
	Sfx.play("kill")


func _process(delta: float) -> void:
	_now += delta
	_hit_progress = minf(1.0, (_now - _hit_at) / HIT_LIFE)
	_marker.visible = _hit_progress < 1.0
	if _marker.visible:
		_marker.queue_redraw()
	var age := _now - _kill_at
	var alpha := clampf(minf(age / 0.08, (KILL_LIFE - age) / 0.35), 0.0, 1.0)
	_skull.visible = alpha > 0.0
	var scale_factor := 1.0 + 0.22 * maxf(0.0, 1.0 - age / 0.14)
	for item: Control in [_kill_label, _streak_label, _skull]:
		item.modulate.a = alpha
		item.pivot_offset = item.size * 0.5
		item.scale = Vector2.ONE * scale_factor


func _draw_hit() -> void:
	var center := _marker.size * 0.5
	for x in [-1, 1]:
		for y in [-1, 1]:
			var axis := Vector2(x, y).normalized()
			var start := center + axis * (HIT_GAP + HIT_SPREAD * _hit_progress)
			var end := start + axis * (HIT_SEG - HIT_SEG_SHRINK * _hit_progress)
			_marker.draw_line(start, end,
					Color(UiDesign.C_BG, 0.9 * (1.0 - _hit_progress)), HIT_OUTLINE_W)
			_marker.draw_line(start, end,
					Color(UiDesign.C_WHITE, 1.0 - _hit_progress), HIT_CORE_W)


func _draw_skull() -> void:
	var origin := (_skull.size - Vector2(64, 64)) * 0.5
	for y in SKULL.size():
		for x in SKULL[y].length():
			var pixel: String = SKULL[y][x]
			var box := Rect2(origin + Vector2(x, y) * SKULL_PX, Vector2(SKULL_PX, SKULL_PX))
			match pixel:
				"#":
					_skull.draw_rect(box.grow(1.0), UiDesign.C_BG)
					_skull.draw_rect(box, UiDesign.C_TEXT)
				"o":
					_skull.draw_rect(box, UiDesign.C_BG)

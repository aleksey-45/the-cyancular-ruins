extends Control

# 干员卡/武器卡编辑器(DevTools,KH-char-weap 分支):开发专用 GUI 工具。
# 只在本分支存在;export_presets.cfg 已排除 DevTools/* → 玩家包不可见。
# 跑法:"C:/Godot/Godot_v4.7.1-stable_win64.exe" --path . res://DevTools/card_editor.tscn
#
# 本文件是装配根(布局/页签/信号接线);职责拆分见各文件头注释:
#   card_schema.gd(卡字段/校验) card_store.gd(磁盘) card_list_panel.gd(列表)
#   card_form_panel.gd(表单) portrait_view.gd(头像) prompt_builder.gd(提示词)
#   agent_runner.gd(Claude CLI 进程) ui_kit.gd(控件工厂)

const BG_COLOR := Color(0.07, 0.09, 0.13)

var _current_type := CardSchema.TYPE_OPERATOR
var _save_status: Label = null
var _body_hbox: HBoxContainer = null
var _tab_op: Button = null
var _tab_wp: Button = null
var _list_slot: Control = null    # 列表占位/真面板的挂点
var _form_slot: Control = null    # 表单占位/真面板的挂点
var _portrait: PortraitView = null


func _ready() -> void:
	# 根 Control 默认 0×0,必须满矩形锚点,否则 1920×1440 视口下布局飞出屏幕(见 royale_lobby.gd 同坑)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	root.add_child(_build_top_bar())
	_body_hbox = HBoxContainer.new()
	_body_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_hbox.add_theme_constant_override("separation", 16)
	root.add_child(_body_hbox)
	_build_body()
	root.add_child(_build_agent_bar())
	root.add_child(_build_log_panel())


# ── 顶栏:标题 + 干员/武器页签 + 保存状态 ──
func _build_top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size = Vector2(0, 72)
	bar.add_theme_constant_override("separation", 24)
	bar.add_child(DevUIKit.label("干员卡 / 武器卡 编辑器", 32, Color(0.55, 0.95, 1.0)))
	var group := ButtonGroup.new()
	_tab_op = DevUIKit.toggle("干 员", 24, group)
	_tab_op.button_pressed = true
	_tab_op.pressed.connect(func() -> void: _select_type(CardSchema.TYPE_OPERATOR))
	bar.add_child(_tab_op)
	_tab_wp = DevUIKit.toggle("武 器", 24, group)
	_tab_wp.pressed.connect(func() -> void: _select_type(CardSchema.TYPE_WEAPON))
	bar.add_child(_tab_wp)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_save_status = DevUIKit.label("", 20, Color(0.65, 0.9, 0.65))
	bar.add_child(_save_status)
	return bar


# ── 主体:卡列表 | 表单 | 头像页(列表/表单在后续提交接入真面板,先占位)──
func _build_body() -> void:
	_list_slot = _placeholder_panel("卡列表(下一提交接入)", 380)
	_body_hbox.add_child(_list_slot)
	_form_slot = _placeholder_panel("表单(下一提交接入)", 0)
	_form_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_hbox.add_child(_form_slot)
	_portrait = PortraitView.new()
	_body_hbox.add_child(_portrait)


func _placeholder_panel(text: String, min_width: int) -> Control:
	var panel := PanelContainer.new()
	if min_width > 0:
		panel.custom_minimum_size = Vector2(min_width, 0)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)
	center.add_child(DevUIKit.label(text, 22, Color(0.5, 0.55, 0.6)))
	return panel


# ── Agent 对接栏(commit 3 接入真按钮,先占位)──
func _build_agent_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size = Vector2(0, 72)
	bar.add_theme_constant_override("separation", 16)
	bar.add_child(DevUIKit.label("Agent 对接:生成提示词 / 发送 Claude Code / 日志(下一提交接入)", 20, Color(0.5, 0.55, 0.6)))
	return bar


func _build_log_panel() -> Control:
	var log := TextEdit.new()
	log.custom_minimum_size = Vector2(0, 260)
	log.editable = false
	log.placeholder_text = "Agent 运行日志(下一提交接入)"
	var pf := DevUIKit.font()
	if pf != null:
		log.add_theme_font_override("font", pf)
		log.add_theme_font_size_override("font_size", 16)
	return log


# ── 页签切换 ──
func _select_type(type: String) -> void:
	_current_type = type
	_portrait.set_card({})

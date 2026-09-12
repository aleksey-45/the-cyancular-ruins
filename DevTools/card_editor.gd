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
const LOG_CAP_CHARS := 200_000   # 日志缓冲上限(超出丢头部,防长任务撑爆 TextEdit)

## 默认 CLI 额外参数:git/Godot 白名单(计划约定的安全默认;勾「全自动」才换 bypassPermissions)
const DEFAULT_EXTRA_FLAGS := "--allowed-tools \"Edit Write Read Glob Grep Bash(git add:*) Bash(git commit:*) Bash(git status:*) Bash(git log:*) Bash(git diff:*)\""

var _current_type := CardSchema.TYPE_OPERATOR
var _save_status: Label = null
var _body_hbox: HBoxContainer = null
var _tab_op: Button = null
var _tab_wp: Button = null
var _tab_prop: Button = null
var _list_panel: CardListPanel = null
var _form_panel: CardFormPanel = null
var _portrait: PortraitView = null

# Agent 对接状态
var _agent: AgentRunner = null
var _btn_send: Button = null
var _btn_stop: Button = null
var _busy_label: Label = null
var _cli_label: Label = null
var _bypass_chk: CheckButton = null
var _extra_args: LineEdit = null
var _log_panel: TextEdit = null
var _log_buffer := ""
var _pending_flags: Array = []       # CARD-DONE 后要翻转的 .state.json 标记
var _pending_template := ""


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
	_agent = AgentRunner.new()
	_agent.log_line.connect(_append_log)
	_agent.finished.connect(_on_agent_finished)
	add_child(_agent)
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
	_tab_prop = DevUIKit.toggle("道 具", 24, group)
	_tab_prop.pressed.connect(func() -> void: _select_type(CardSchema.TYPE_PROP))
	bar.add_child(_tab_prop)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_save_status = DevUIKit.label("", 20, Color(0.65, 0.9, 0.65))
	bar.add_child(_save_status)
	return bar


# ── 主体:卡列表 | 表单 | 头像页 ──
func _build_body() -> void:
	_list_panel = CardListPanel.new()
	_list_panel.card_selected.connect(_on_card_selected)
	_body_hbox.add_child(_list_panel)
	_form_panel = CardFormPanel.new()
	_form_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form_panel.card_saved.connect(_on_card_saved)
	_form_panel.save_failed.connect(_on_save_failed)
	_body_hbox.add_child(_form_panel)
	_portrait = PortraitView.new()
	_body_hbox.add_child(_portrait)


func _on_card_selected(card: Dictionary) -> void:
	_form_panel.set_card(card)
	_portrait.set_card(card)


func _on_card_saved(card: Dictionary) -> void:
	_save_status.text = "已保存 %s(rev %d)" % [Time.get_time_string_from_system(), int(card.get("rev", 0))]
	_save_status.add_theme_color_override("font_color", Color(0.65, 0.9, 0.65))
	_list_panel.reload_list(true)   # 静默刷新条目名(改名后列表同步;不打断表单输入)


func _on_save_failed(errs: Array[String]) -> void:
	_save_status.text = "未保存:%s" % " / ".join(errs)
	_save_status.add_theme_color_override("font_color", Color(0.95, 0.6, 0.5))


# ── Agent 对接栏:生成提示词 / 发送 Claude Code / 停止 / 权限档位 / CLI 状态 ──
func _build_agent_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size = Vector2(0, 72)
	bar.add_theme_constant_override("separation", 12)
	bar.add_child(DevUIKit.label("Agent", 24, Color(0.55, 0.95, 1.0)))
	bar.add_child(DevUIKit.button("生成提示词→剪贴板", 18, _on_copy_prompt))
	_btn_send = DevUIKit.button("发送给 Claude Code", 18, _on_send_agent)
	bar.add_child(_btn_send)
	_btn_stop = DevUIKit.button("停 止", 18, func() -> void: _agent.stop())
	_btn_stop.disabled = true
	bar.add_child(_btn_stop)
	_busy_label = DevUIKit.label("", 18, Color(0.95, 0.85, 0.4))
	bar.add_child(_busy_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_bypass_chk = DevUIKit.check("全自动(跳过权限确认,慎用)", false)
	_bypass_chk.tooltip_text = "默认 acceptEdits+白名单;勾上后 CLI 改用 bypassPermissions(agent 无审批改文件/跑命令)"
	bar.add_child(_bypass_chk)
	bar.add_child(DevUIKit.label("CLI额外参数", 16, Color(0.5, 0.55, 0.6)))
	_extra_args = DevUIKit.line_edit("", DEFAULT_EXTRA_FLAGS)
	_extra_args.custom_minimum_size = Vector2(420, 40)
	_extra_args.tooltip_text = "追加给 claude -p 的原样参数(默认 git/Godot 白名单)"
	bar.add_child(_extra_args)
	bar.add_child(DevUIKit.button("日志目录", 16, _on_open_log_dir))
	_cli_label = DevUIKit.label("", 16, Color(0.5, 0.55, 0.6))
	bar.add_child(_cli_label)
	_probe_cli.call_deferred()
	return bar


func _build_log_panel() -> Control:
	_log_panel = TextEdit.new()
	_log_panel.custom_minimum_size = Vector2(0, 240)
	_log_panel.editable = false
	_log_panel.placeholder_text = "Agent 运行日志(生成提示词/发送 Claude Code 后在此滚动)"
	var pf := DevUIKit.font()
	if pf != null:
		_log_panel.add_theme_font_override("font", pf)
		_log_panel.add_theme_font_size_override("font_size", 16)
	return _log_panel


# ── Agent 动作 ──

## CLI 预探测(延后一帧,不卡 _ready);失败只提示,不拦「复制提示词」兜底
func _probe_cli() -> void:
	var probe := AgentRunner.cli_available()
	if bool(probe["ok"]):
		_cli_label.text = "CLI 就绪"
		_cli_label.add_theme_color_override("font_color", Color(0.65, 0.9, 0.65))
	else:
		_cli_label.text = "CLI 不可用→用复制兜底"
		_cli_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.4))


## 取当前选中卡并生成提示词;返回 PromptBuilder 结果(失败广播日志并返回空字典)
func _build_prompt_for_current() -> Dictionary:
	var card := _list_panel.current_card()
	if card.is_empty():
		_append_log("[提示] 先在左侧选中(或新建)一张卡再生成提示词")
		return {}
	var built := PromptBuilder.build(card, CardStore.load_state())
	_append_log("[提示词] %s(%s / %s rev%d)已生成并复制到剪贴板,%d 字" % [
			str(built["template"]), str(card.get("card_type", "")), str(card.get("id", "")),
			int(card.get("rev", 0)), str(built["prompt"]).length()])
	return built


func _on_copy_prompt() -> void:
	var built := _build_prompt_for_current()
	if built.is_empty():
		return
	DisplayServer.clipboard_set(str(built["prompt"]))


func _on_send_agent() -> void:
	var built := _build_prompt_for_current()
	if built.is_empty():
		return
	var perm := "bypassPermissions" if _bypass_chk.button_pressed else "acceptEdits"
	_pending_flags = built["set_flags"]
	_pending_template = str(built["template"])
	var tag := _agent.run(_list_panel.current_card(), str(built["prompt"]), _extra_args.text, perm)
	if not tag.is_empty():
		_set_busy(true)


func _on_agent_finished(ok: bool, card_done: bool, _summary: String) -> void:
	_set_busy(false)
	# 施工完成后刷新当前卡头像(agent 可能生成了新 PNG)
	_portrait.set_card(_list_panel.current_card())
	if card_done and not _pending_flags.is_empty():
		var state := CardStore.load_state()
		for f in _pending_flags:
			state[f] = true
		CardStore.save_state(state)
		_append_log("[状态] .state.json 标记已翻转:%s(下次同类卡走 NEXT 模板)" % ", ".join(PackedStringArray(_pending_flags)))
	elif ok and not card_done:
		_append_log("[提醒] CLI 正常退出但日志里没有 CARD-DONE 完成标记——请人工检查施工结果与 .state.json")
	elif not ok:
		_append_log("[提醒] CLI 异常退出(看上方日志/日志目录里完整输出);.state.json 未动")
	_pending_flags = []
	_pending_template = ""


func _set_busy(busy: bool) -> void:
	_btn_send.disabled = busy
	_btn_stop.disabled = not busy
	_busy_label.text = "施工中…" if busy else ""


func _on_open_log_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(AgentRunner.LOG_DIR))
	OS.shell_open(ProjectSettings.globalize_path(AgentRunner.LOG_DIR))


func _append_log(text: String) -> void:
	if _log_panel == null:
		return
	_log_buffer += text + "\n"
	if _log_buffer.length() > LOG_CAP_CHARS:
		_log_buffer = _log_buffer.substr(_log_buffer.length() - LOG_CAP_CHARS / 2)
	_log_panel.text = _log_buffer
	# Godot 4.7 的 TextEdit 没有 scroll_to_line:直接把垂直滚动条顶到底部
	var bar := _log_panel.get_v_scroll_bar()
	if bar != null:
		bar.value = bar.max_value


# ── 页签切换:列表重载(选中第一张会经 card_selected 驱动表单/头像)──
func _select_type(type: String) -> void:
	_current_type = type
	_list_panel.set_type(type)

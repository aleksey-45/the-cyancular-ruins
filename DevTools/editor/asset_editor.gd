extends Control

# 素材编辑器(DevTools/editor 重写版):武器 / 角色 / 道具 三类卡。
# 布局:左=类型+卡列表;中=表单(按 schema 驱动)+ 特殊要求;右=美术槽(上传/导出占位/
# AI占位/删除)+ 施工(生成提示词/复制/发送本机 Claude Code/停止)+ 日志。
# 核心原则:美术资产画师产出制 —— 每个美术槽都可人工上传,AI 生成仅占位;
# 施工信息经 EditorPrompt 转写,经 AgentLink 传输层发出(可换 API 实现)。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"
const CYAN := Color(0.55, 0.95, 1.0)
const GREY := Color(0.75, 0.8, 0.85)
const GOLD := Color(0.95, 0.9, 0.6)

var _type := EditorSchema.TYPE_WEAPON
var _card: Dictionary = {}
var _field_editors: Dictionary = {}    # key -> Control
var _skills_editors: Array = []        # [{name, cooldown, desc}]
var _kind_params_edit: LineEdit = null
var _notes_edit: TextEdit = null
var _slot_rows: VBoxContainer = null
var _preview: TextureRect = null
var _list: ItemList = null
var _form_box: VBoxContainer = null
var _status: Label = null
var _log: RichTextLabel = null
var _link = null                       # AgentLink
var _file_dialog: FileDialog = null
var _file_mode := ""                   # import / export
var _file_slot := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := _label("素材编辑器 —— 武器 / 角色 / 道具(美术画师产出制,AI 仅占位)", 26, CYAN)
	title.position = Vector2(20, 12)
	add_child(title)
	var row := HBoxContainer.new()
	row.position = Vector2(20, 52)
	row.size = Vector2(1880, 1330)
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	# ── 左:类型 + 列表 ──
	var left := _panel(row, 300)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	left.add_child(tabs)
	for t in EditorSchema.CARD_TYPES:
		var b := _btn(str(EditorSchema.TYPE_LABELS[t]), 22, func() -> void: _switch_type(t))
		b.toggle_mode = true
		tabs.add_child(b)
	left.add_child(_spacer(8))
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(280, 420)
	_list.item_selected.connect(func(idx: int) -> void: _open_card(str(_list.get_item_metadata(idx))))
	left.add_child(_list)
	left.add_child(_btn("新建(示范模板)", 20, _new_from_sample))
	left.add_child(_btn("新建(空白)", 20, _new_blank))
	left.add_child(_btn("复制本卡", 20, _duplicate_card))
	left.add_child(_btn("删除本卡", 20, _delete_card))
	var help := _label("美术约定:所有素材正式版由画师上传;\nAI 生成仅占位。槽位文件可导出给画师改图。", 16, GREY)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(280, 0)
	left.add_child(help)

	# ── 中:表单 ──
	var mid := _panel(row, 760)
	var mid_scroll := ScrollContainer.new()
	mid_scroll.custom_minimum_size = Vector2(740, 900)
	mid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(mid_scroll)
	_form_box = VBoxContainer.new()
	_form_box.custom_minimum_size = Vector2(720, 0)
	_form_box.add_theme_constant_override("separation", 6)
	mid_scroll.add_child(_form_box)
	mid.add_child(_label("特殊要求(逐字进施工提示词,画师/策划约定写这里):", 18, GOLD))
	_notes_edit = TextEdit.new()
	_notes_edit.custom_minimum_size = Vector2(740, 110)
	_notes_edit.text_changed.connect(func() -> void:
		if not _card.is_empty():
			_card["notes"] = _notes_edit.text
			_save_silent())
	mid.add_child(_notes_edit)

	# ── 右:美术槽 + 施工 ──
	var right := _panel(row, 780)
	right.add_child(_label("美术素材槽(点击行预览;[人工]=画师上传,[AI占位]=临时)", 20, CYAN))
	_slot_rows = VBoxContainer.new()
	_slot_rows.add_theme_constant_override("separation", 4)
	right.add_child(_slot_rows)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(240, 240)
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview)
	right.add_child(_spacer(6))
	right.add_child(_label("施工(经传输层发给本机 Claude Code;传输层可换 API 实现):", 20, CYAN))
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 8)
	right.add_child(mrow)
	mrow.add_child(_label("模型覆盖", 18, GREY))
	var model_edit := LineEdit.new()
	model_edit.custom_minimum_size = Vector2(260, 0)
	model_edit.text = Settings.agent_model
	model_edit.placeholder_text = "留空=跟随 ~/.claude;智谱端点填 glm-5.3-flash"
	model_edit.tooltip_text = "显式 --model 钉住模型:主模型配置指向端点上不存在的模型时会 400 退出(exit 1),填可用模型即可"
	model_edit.text_changed.connect(func(v: String) -> void:
		Settings.agent_model = v.strip_edges()
		Settings.save())
	mrow.add_child(model_edit)
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 8)
	right.add_child(arow)
	arow.add_child(_btn("生成提示词+发送", 20, _send_agent))
	arow.add_child(_btn("仅复制提示词", 20, _copy_prompt))
	arow.add_child(_btn("停止", 20, func() -> void:
		if _link != null:
			_link.stop()))
	_status = _label("", 18, GREY)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(760, 0)
	right.add_child(_status)
	_log = RichTextLabel.new()
	_log.custom_minimum_size = Vector2(760, 220)
	_log.scroll_following = true
	right.add_child(_log)

	_link = load("res://DevTools/editor/agent_link.gd").new()
	_link.log_line.connect(func(t: String) -> void: _log.append_text(t.replace("[", "\\[") + "\n"))
	_link.finished.connect(_on_agent_finished)
	_switch_type(_type)


func _on_agent_finished(ok: bool, done: bool, s: String) -> void:
	_status.text = ("施工完成:" if ok else "施工异常:") + s + ("(已回报 CARD-DONE)" if done else "(未见 CARD-DONE,检查日志)")
	_refresh_slots()


# ── 数据流 ──
func _switch_type(t: String) -> void:
	_type = t
	_card = {}
	_refresh_list()
	_rebuild_form()
	_refresh_slots()

func _refresh_list() -> void:
	_list.clear()
	for id in EditorStore.list_ids(_type):
		var c := EditorStore.load_card(_type, id)
		var idx := _list.add_item("%s  (%s)" % [str(c.get("name", id)), id])
		_list.set_item_metadata(idx, id)

func _open_card(id: String) -> void:
	_card = EditorStore.load_card(_type, id)
	if _card.is_empty():
		_status.text = "读卡失败:%s" % id
		return
	_rebuild_form()
	_refresh_slots()
	_status.text = "已打开 %s(%s)" % [id, _type]

func _new_from_sample() -> void:
	_card = EditorSchema.sample_template(_type)
	_card["id"] = _auto_id()
	_card["created_at"] = Time.get_datetime_string_from_system()
	_save_silent()
	_refresh_list()
	_rebuild_form()
	_refresh_slots()
	_status.text = "已从示范模板新建 %s(id 可在下方修改保存)" % _card["id"]

func _new_blank() -> void:
	_card = EditorSchema.make_default(_type, _auto_id())
	_save_silent()
	_refresh_list()
	_rebuild_form()
	_refresh_slots()

func _duplicate_card() -> void:
	if _card.is_empty():
		return
	var c := _card.duplicate(true)
	c["id"] = _auto_id()
	c["name"] = str(c.get("name", "")) + "副本"
	c["rev"] = 1
	_card = c
	_save_silent()
	_refresh_list()
	_rebuild_form()
	_refresh_slots()

func _delete_card() -> void:
	if _card.is_empty():
		return
	EditorStore.delete_card(_type, str(_card["id"]))
	_card = {}
	_refresh_list()
	_rebuild_form()
	_refresh_slots()
	_status.text = "已删除(含美术槽文件)"

func _auto_id() -> String:
	var prefix: String = {"weapon": "wp", "operator": "op", "prop": "pr"}[_type]
	return "%s_%s" % [prefix, str(Time.get_ticks_msec() % 1000000)]

func _save_silent() -> void:
	if _card.is_empty():
		return
	var err := EditorStore.save_card(_card)
	if err != "":
		_status.text = err

# ── 表单 ──
func _rebuild_form() -> void:
	for c in _form_box.get_children():
		c.queue_free()
	_field_editors.clear()
	_skills_editors.clear()
	if _card.is_empty():
		var tip := _label("← 左侧选卡或新建。新建时可选「示范模板」:\n每类字段含义即模板示例内容,备注写特殊要求。", 20, GREY)
		tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_form_box.add_child(tip)
		return
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	_form_box.add_child(grid)
	# id(可改,改名=存新删旧)
	grid.add_child(_label("id", 18, GREY))
	var id_edit := LineEdit.new()
	id_edit.custom_minimum_size = Vector2(300, 0)
	id_edit.text = str(_card.get("id", ""))
	id_edit.text_submitted.connect(func(t: String) -> void: _rename_card(t.strip_edges()))
	grid.add_child(id_edit)
	_field_editors["id"] = id_edit
	for f in EditorSchema.fields_for(_type):
		var key := str(f["key"])
		var label := str(f["label"])
		grid.add_child(_label(label, 18, GREY))
		match str(f["kind"]):
			"bool":
				var cb := CheckButton.new()
				cb.button_pressed = bool(_card.get(key, false))
				cb.toggled.connect(func(on: bool) -> void: _set_field(key, on))
				grid.add_child(cb)
				_field_editors[key] = cb
			"choice":
				var ob := OptionButton.new()
				for ch in f["choices"]:
					ob.add_item(str(ch))
				ob.selected = maxf(0, (f["choices"] as Array).find(str(_card.get(key, ""))))
				ob.item_selected.connect(func(idx: int) -> void: _set_field(key, f["choices"][idx]))
				grid.add_child(ob)
				_field_editors[key] = ob
			"int":
				var sp := SpinBox.new()
				sp.min_value = -999999
				sp.max_value = 999999
				sp.step = 1
				sp.value = float(_card.get(key, 0))
				sp.value_changed.connect(func(v: float) -> void: _set_field(key, int(v)))
				grid.add_child(sp)
				_field_editors[key] = sp
			"float":
				var sp2 := SpinBox.new()
				sp2.min_value = -999999.0
				sp2.max_value = 999999.0
				sp2.step = 0.01
				sp2.value = float(_card.get(key, 0.0))
				sp2.value_changed.connect(func(v: float) -> void: _set_field(key, v))
				grid.add_child(sp2)
				_field_editors[key] = sp2
			_:
				var le := LineEdit.new()
				le.custom_minimum_size = Vector2(560, 0)
				le.text = str(_card.get(key, ""))
				le.text_changed.connect(func(t: String) -> void: _set_field(key, t))
				grid.add_child(le)
				_field_editors[key] = le
	# 干员:技能 3 行
	if _type == EditorSchema.TYPE_OPERATOR:
		_form_box.add_child(_label("技能(≤3;键位 skill_1~3 = Z/X/C)", 20, CYAN))
		var skills: Array = _card.get("skills", [])
		for i in EditorSchema.MAX_SKILLS:
			var s: Dictionary = skills[i] if i < skills.size() and typeof(skills[i]) == TYPE_DICTIONARY else {}
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			var ne := LineEdit.new()
			ne.placeholder_text = "技能%d名称" % (i + 1)
			ne.text = str(s.get("name", ""))
			ne.custom_minimum_size = Vector2(160, 0)
			var ce := SpinBox.new()
			ce.min_value = 0.0
			ce.max_value = 999.0
			ce.step = 0.5
			ce.value = float(s.get("cooldown", 10.0))
			var de := LineEdit.new()
			de.placeholder_text = "效果描述"
			de.text = str(s.get("desc", ""))
			de.custom_minimum_size = Vector2(380, 0)
			var idx := i
			var capture := func(_t: String) -> void: _set_skill(idx, ne.text, ce.value, de.text)
			ne.text_changed.connect(capture)
			de.text_changed.connect(capture)
			ce.value_changed.connect(func(_v: float) -> void: _set_skill(idx, ne.text, ce.value, de.text))
			row.add_child(ne)
			row.add_child(ce)
			row.add_child(de)
			_form_box.add_child(row)
			_skills_editors.append({"name": ne, "cooldown": ce, "desc": de})
	# 道具/武器:kind_params JSON 行
	if _type == EditorSchema.TYPE_PROP or (_type == EditorSchema.TYPE_WEAPON and str(_card.get("kind")) in ["melee", "thrown"]):
		_form_box.add_child(_label("kind_params(JSON,如 {\"fuse_time\":0.5}):", 18, GREY))
		_kind_params_edit = LineEdit.new()
		_kind_params_edit.text = JSON.stringify(_card.get("kind_params", {}))
		_kind_params_edit.text_changed.connect(func(t: String) -> void:
			var parsed: Variant = JSON.parse_string(t)
			if typeof(parsed) == TYPE_DICTIONARY:
				_card["kind_params"] = parsed
				_save_silent())
		_form_box.add_child(_kind_params_edit)
	_notes_edit.text = str(_card.get("notes", ""))

func _set_field(key: String, value) -> void:
	if _card.is_empty():
		return
	_card[key] = value
	if key == "id":
		return
	_save_silent()

func _set_skill(idx: int, name: String, cooldown: float, desc: String) -> void:
	if _card.is_empty() or str(name).strip_edges() == "" and str(desc).strip_edges() == "":
		return
	var skills: Array = _card.get("skills", [])
	while skills.size() <= idx:
		skills.append({"name": "", "key": EditorSchema.SKILL_KEYS[mini(idx, 2)], "cooldown": 10.0, "desc": ""})
	var s: Dictionary = skills[idx]
	s["name"] = name
	s["key"] = EditorSchema.SKILL_KEYS[idx]
	s["cooldown"] = cooldown
	s["desc"] = desc
	skills[idx] = s
	_card["skills"] = skills
	_save_silent()

func _rename_card(new_id: String) -> void:
	if _card.is_empty() or new_id == str(_card["id"]) or new_id == "":
		return
	if RegEx.create_from_string(EditorSchema.ID_REGEX).search(new_id) == null:
		_status.text = "id 非法(小写字母开头,2~32 位小写/数字/下划线)"
		return
	var old_id := str(_card["id"])
	var old_type := _type
	_card["id"] = new_id
	var err := EditorStore.save_card(_card)
	if err != "":
		_status.text = err
		_card["id"] = old_id
		return
	EditorStore.delete_card(old_type, old_id)
	_status.text = "已改名 %s → %s" % [old_id, new_id]
	_refresh_list()
	_refresh_slots()

# ── 美术槽 ──
func _refresh_slots() -> void:
	for c in _slot_rows.get_children():
		c.queue_free()
	if _card.is_empty():
		_slot_rows.add_child(_label("(未选卡)", 18, GREY))
		_preview.texture = null
		return
	for s in EditorSchema.art_slots(_type, str(_card["id"])):
		var slot_key := str(s["key"])
		var st := EditorArt.slot_status(_type, str(_card["id"]), slot_key)
		var tag := "[人工]" if st == "human" else ("[AI占位]" if st == "ai" else "[缺失]")
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lab := _label("%s %s" % [tag, s["label"]], 18,
				Color(0.6, 1.0, 0.7) if st == "human" else (GOLD if st == "ai" else Color(1.0, 0.6, 0.6)))
		lab.tooltip_text = "%s\n游戏侧:%s\n文件:%s" % [s["desc"], s["game"], s["file"]]
		lab.mouse_filter = Control.MOUSE_FILTER_STOP
		row.add_child(lab)
		row.add_child(_btn("上传", 16, func() -> void: _pick_file("import", slot_key)))
		row.add_child(_btn("导出", 16, func() -> void: _pick_file("export", slot_key)))
		row.add_child(_btn("AI占位", 16, func() -> void:
			var err: String = EditorArt.make_ai_placeholder(_type, str(_card["id"]), slot_key)
			_status.text = err if err != "" else "已生成 AI 占位(%s)" % slot_key
			_refresh_slots()))
		row.add_child(_btn("删除", 16, func() -> void:
			EditorArt.clear_slot(_type, str(_card["id"]), slot_key)
			_refresh_slots()))
		lab.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
				_show_preview(slot_key))
		row.add_child(_btn("预览", 16, func() -> void: _show_preview(slot_key)))
		_slot_rows.add_child(row)

func _show_preview(slot_key: String) -> void:
	var p := EditorArt.slot_abs_path(_type, str(_card["id"]), slot_key)
	if p != "" and FileAccess.file_exists(p):
		_preview.texture = ImageTexture.create_from_image(Image.load_from_file(p))
	else:
		_preview.texture = null
		_status.text = "该槽位还没有图"

func _pick_file(mode: String, slot_key: String) -> void:
	if _card.is_empty():
		return
	_file_mode = mode
	_file_slot = slot_key
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_selected.connect(_on_file_picked)
		add_child(_file_dialog)
	if mode == "import":
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.filters = ["*.png ; PNG", "*.webp ; WebP", "*.jpg ; JPEG"]
	else:
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.filters = ["*.png ; PNG"]
		_file_dialog.current_file = "%s__%s.png" % [str(_card["id"]), slot_key]
	_file_dialog.popup_centered(Vector2i(900, 600))

func _on_file_picked(path: String) -> void:
	if _card.is_empty():
		return
	if _file_mode == "import":
		var err: String = EditorArt.import_file(_type, str(_card["id"]), _file_slot, path)
		_status.text = err if err != "" else "已上传人工素材:%s(%s 槽,标记 [人工])" % [path.get_file(), _file_slot]
	else:
		var err2: String = EditorArt.export_slot(_type, str(_card["id"]), _file_slot, path)
		_status.text = err2 if err2 != "" else "已导出当前槽位图到 %s(画师可直接在其上绘制)" % path
	_refresh_slots()

# ── 施工 ──
func _send_agent() -> void:
	if _card.is_empty():
		_status.text = "先选卡"
		return
	_save_silent()
	var prompt := EditorPrompt.build(_card, EditorPrompt.art_report_lines(_type, str(_card["id"])))
	_log.clear()
	_log.append_text("[提示词已生成 %d 字符]\n" % prompt.length())
	_link.run(str(_card["card_type"]), str(_card["id"]), prompt, null, Settings.agent_model)

func _copy_prompt() -> void:
	if _card.is_empty():
		return
	DisplayServer.clipboard_set(EditorPrompt.build(_card, EditorPrompt.art_report_lines(_type, str(_card["id"]))))
	_status.text = "提示词已复制到剪贴板(可粘贴到任意 CLI/会话)"

# ── UI 工厂 ──
func _panel(row: HBoxContainer, w: int) -> VBoxContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(w, 0)
	row.add_child(p)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	return vb

func _label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	var pf: FontFile = load(PIXEL_FONT)
	if pf != null:
		l.add_theme_font_override("font", pf)
	return l

func _btn(text: String, size: int, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	var pf: FontFile = load(PIXEL_FONT)
	if pf != null:
		b.add_theme_font_override("font", pf)
	b.pressed.connect(cb)
	return b

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

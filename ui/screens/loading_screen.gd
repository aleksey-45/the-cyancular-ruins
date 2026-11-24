class_name LoadingScreen
extends CanvasLayer

# 载入界面(P0,设计系统 v2):CanvasLayer(200)全屏遮罩 + HeaderStrip + 阶段进度条。
# ★ 职责单一:只负责"显示/更新/隐藏"以及加载期间的输入拦截;场景构建与换场由 SceneTransition 驱动。
# ★ API(计划 P0 §2.1):show_loading(text) / set_progress(p, text) / hide_loading();
#   失败态另有 show_failure(text) + back_requested 信号,保证加载失败不白屏、可返回。
# ★ 构建是同步 GDScript,没有资源级回调 —— 进度只表示**阶段**(0/0.15/0.55/0.85/1),不伪造细粒度。
# ★ 样式只用 UiDesign token / Theme 2.0 variation:不写 Color 字面量、不写 StyleBox、不写绝对坐标。
# ★ 按需挂到 tree.root:遮罩要活过换场那一帧;hide_loading 后自行释放,不常驻场景。

signal dismissed

const SCENE_PATH := "res://scenes/loading_screen.tscn"
const HEADER_LOADING := "载 入 中"
const HEADER_FAILED := "载 入 失 败"
# 卡片最小宽度:内容驱动(640 = 1280×960 下左右各留 320 的安全宽度),不是屏幕坐标反推。
const CARD_MIN_W := UiDesign.SP_10 * 8
# 进度条厚度:8px(SP_2),描边/底色都取 token。
const BAR_H := UiDesign.SP_2

var _root: Control
var _dim: ColorRect
var _card: PanelContainer
var _header_text: Label
var _status: Label
var _bar: Control
var _track: ColorRect
var _fill: ColorRect
var _percent: Label
var _hint: Label
var _error: Label
var _back: Button
var _busy := false


# ── 静态挂载:同一个 root 只留一个载入层,按需创建 ─────────────────────────────
static func find(tree: SceneTree) -> LoadingScreen:
	if tree == null or tree.root == null:
		return null
	for child in tree.root.get_children():
		if child is LoadingScreen and not child.is_queued_for_deletion():
			return child
	return null


static func mount(tree: SceneTree) -> LoadingScreen:
	if tree == null or tree.root == null:
		return null
	var existing := find(tree)
	if existing != null:
		return existing
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		return null
	var screen := packed.instantiate() as LoadingScreen
	if screen == null:
		return null
	tree.root.add_child(screen)
	return screen


func _ready() -> void:
	# 载入层必须在暂停/换场时仍然响应:process_mode=ALWAYS(tscn 里也写了一份,裸挂脚本时兜底)。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_ui()
	_root.visible = false


# ── 公开 API ────────────────────────────────────────────────────────────────

func show_loading(text := "") -> void:
	_ensure_ui()
	_busy = true
	_root.visible = true
	_header_text.text = HEADER_LOADING
	_header_text.add_theme_color_override("font_color", UiDesign.C_GOLD)
	_status.visible = true
	_bar.visible = true
	_track.visible = true
	_fill.visible = true
	_percent.visible = true
	_hint.visible = true
	_error.visible = false
	_back.visible = false
	_status.text = text if not text.is_empty() else "正在载入…"
	set_progress(0.0, "")


func set_progress(progress: float, text := "") -> void:
	_ensure_ui()
	var p := clampf(progress, 0.0, 1.0)
	# 进度条宽度用锚点比例表达(布局,不是绝对坐标):anchor_right=p 即按父宽百分比填充。
	_fill.anchor_right = p
	_fill.offset_left = 0.0
	_fill.offset_right = 0.0
	_fill.visible = p > 0.0
	_percent.text = "%d%%" % roundi(p * 100.0)
	if not text.is_empty():
		_status.text = text


func show_failure(text: String) -> void:
	_ensure_ui()
	# 失败态:停止拦截输入,露出"返回"按钮;遮罩保留,不白屏。
	_busy = false
	_root.visible = true
	_header_text.text = HEADER_FAILED
	_header_text.add_theme_color_override("font_color", UiDesign.C_DANGER)
	_status.visible = false
	_bar.visible = false
	_track.visible = false
	_fill.visible = false
	_percent.visible = false
	_hint.visible = false
	_error.text = text
	_error.visible = true
	_back.visible = true


func hide_loading() -> void:
	_busy = false
	if _root != null:
		_root.visible = false
	# 载入层用完即释放:不常驻 root,不会挡住后续场景/输入。
	queue_free()


func is_loading() -> bool:
	return _busy and _root != null and _root.visible


# ── 输入拦截 ────────────────────────────────────────────────────────────────
# 加载期间(_busy)把所有输入标记为已处理:鼠标被 Dim 的 MOUSE_FILTER_STOP 挡住,键盘在这里挡住,
# 两种手段缺一不可(只挡鼠标时 _unhandled_input 仍会送进旧场景)。
func _input(event: InputEvent) -> void:
	if _busy and _root != null and _root.visible:
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# 失败态:Esc 也能返回(失败时 _busy=false,不再吞输入)。
	if not _busy and _root != null and _root.visible and _back != null and _back.visible \
			and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back()


func _on_back() -> void:
	dismissed.emit()
	hide_loading()


# ── 结构与样式 ──────────────────────────────────────────────────────────────

func _ensure_ui() -> void:
	if _root != null:
		return
	# 优先用 scenes/loading_screen.tscn 的结构;裸脚本挂 CanvasLayer 时就地构建同一套结构(与暂停菜单同约定)。
	var existing := get_node_or_null("Root") as Control
	if existing != null:
		_root = existing
		_dim = $Root/Dim as ColorRect
		_card = $Root/Center/Card as PanelContainer
		_header_text = $Root/Center/Card/Body/Header/HeaderText as Label
		_status = $Root/Center/Card/Body/Status as Label
		_bar = $Root/Center/Card/Body/Bar as Control
		_track = $Root/Center/Card/Body/Bar/Track as ColorRect
		_fill = $Root/Center/Card/Body/Bar/Fill as ColorRect
		_percent = $Root/Center/Card/Body/Percent as Label
		_hint = $Root/Center/Card/Body/Hint as Label
		_error = $Root/Center/Card/Body/Error as Label
		_back = $Root/Center/Card/Body/Back as Button
	else:
		_build_ui()
	_apply_layout()
	_apply_style()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.theme = UiDesign.MENU_THEME
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_card = UiDesign.ui_panel("card")
	_card.name = "Card"
	center.add_child(_card)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	_card.add_child(body)

	var header := UiDesign.header_strip("", UiDesign.T_H2, true)
	header.name = "Header"
	body.add_child(header)
	_header_text = header.get_child(0) as Label
	_header_text.name = "HeaderText"

	_status = UiDesign.ui_label("", "body")
	_status.name = "Status"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_status)

	_bar = Control.new()
	_bar.name = "Bar"
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.custom_minimum_size = Vector2(0, BAR_H)
	body.add_child(_bar)
	_track = ColorRect.new()
	_track.name = "Track"
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bar.add_child(_track)
	_fill = ColorRect.new()
	_fill.name = "Fill"
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bar.add_child(_fill)

	_percent = UiDesign.ui_label("", "body")
	_percent.name = "Percent"
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	body.add_child(_percent)

	_hint = UiDesign.ui_label("", "dim")
	_hint.name = "Hint"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_hint)

	_error = UiDesign.ui_label("", "body")
	_error.name = "Error"
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_error)

	_back = UiDesign.ui_button("返回", UiDesign.T_H2, Vector2(CARD_MIN_W, 0), "quiet")
	_back.name = "Back"
	body.add_child(_back)

	_back.pressed.connect(_on_back)


func _apply_layout() -> void:
	_card.custom_minimum_size = Vector2(CARD_MIN_W, 0)
	var body := _card.get_node("Body") as VBoxContainer
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	_bar.custom_minimum_size = Vector2(0, BAR_H)


func _apply_style() -> void:
	# 颜色/字号全部引 UiDesign token;文字内容由 show_loading/show_failure 决定。
	_dim.color = UiDesign.C_BG
	_track.color = UiDesign.C_BORDER_DIM
	_fill.color = UiDesign.C_ACCENT
	_hint.text = "构建期间请稍候，输入已暂时锁定"
	_header_text.text = HEADER_LOADING
	_header_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_header_text.add_theme_color_override("font_color", UiDesign.C_GOLD)
	UiDesign.style_control(_header_text, UiDesign.T_H2)
	UiDesign.style_control(_status, UiDesign.T_SMALL)
	_status.add_theme_color_override("font_color", UiDesign.C_TEXT)
	UiDesign.style_control(_percent, UiDesign.T_H2)
	_percent.add_theme_color_override("font_color", UiDesign.C_ACCENT)
	UiDesign.style_control(_hint, UiDesign.T_BODY)
	_hint.add_theme_color_override("font_color", UiDesign.C_TEXT_DIM)
	UiDesign.style_control(_error, UiDesign.T_SMALL)
	_error.add_theme_color_override("font_color", UiDesign.C_DANGER)
	_apply_layout()

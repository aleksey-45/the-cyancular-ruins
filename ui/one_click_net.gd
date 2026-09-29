class_name OneClickNet
extends Control

# 一键联机面板(三个联机页共用,照 MapPicker 的"共用控件"模式):
# 全屏遮罩 + 居中面板,只负责**虚拟网**这一层——房主「一键开网」拿邀请码、朋友「粘码加入」。
# 开服/连大厅不归它管:就绪后发 net_ready(虚拟IP, 是否房主),由 LobbyPage 那边
# 走 LocalServer.restart() + _request_list()(见 lobby_page._on_one_click_net_ready)。
#
# ★ 交互抄 MCTier 的可用之处:邀请码剪贴板自动识别(面板一开,剪贴板里有 CYR1- 码就预填)、
#   一键复制、失败原因直接把内核日志尾巴带出来。全程不出现"网络名/密码/节点/IP"这些词。

signal net_ready(addr: String, is_host: bool)
signal closed

var _panel: PanelContainer
var _status: Label
var _host_btn: Button
var _join_btn: Button
var _code_edit: LineEdit        # 房主=只读邀请码回显;朋友=粘贴输入(两用)
var _copy_btn: Button
var _join_go_btn: Button
var _stop_btn: Button

var _busy := false             # 一次只让一个流程跑(按钮互斥)
var _hosted := false           # 本面板生命周期内是否已开过网(成功后按钮转"已开网")


func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # 遮罩吃掉点击,不穿透到底下的大厅页


func setup() -> void:
	# 全屏半透明遮罩
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(760, 0)
	_panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.custom_minimum_size = Vector2(720, 0)
	_panel.add_child(vb)

	vb.add_child(UiFactory.label("一 键 联 机(虚拟局域网,免公网服务器)", 32, UiFactory.C_ACCENT))
	vb.add_child(UiFactory.label("同一张虚拟网里的人互相当局域网玩。房主先「一键开网」,\n把邀请码发给朋友;朋友复制后点「加入」即可,无需任何配置。\n(开网会弹一次 Windows 管理员授权——创建虚拟网卡需要)", 16, UiFactory.C_TEXT_DIM))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vb.add_child(row)
	_host_btn = UiFactory.button("我是房主:一键开网", 16, Vector2(300, 52))
	_host_btn.pressed.connect(_on_host_pressed)
	row.add_child(_host_btn)
	_join_btn = UiFactory.button("我是朋友:粘贴邀请码", 16, Vector2(300, 52))
	_join_btn.pressed.connect(_on_join_pressed)
	row.add_child(_join_btn)

	vb.add_child(UiFactory.label("邀请码 / 粘贴区", 16, UiFactory.C_TEXT_DIM))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 10)
	vb.add_child(crow)
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "房主:这里会出现邀请码    朋友:把邀请码粘贴到这里"
	_code_edit.custom_minimum_size = Vector2(0, 44)
	_code_edit.editable = true
	UiFactory.style_control(_code_edit, 16)
	crow.add_child(_code_edit)
	_copy_btn = UiFactory.button("复制邀请码", 16, Vector2(160, 44))
	_copy_btn.pressed.connect(_on_copy_pressed)
	crow.add_child(_copy_btn)
	_join_go_btn = UiFactory.button("加 入", 16, Vector2(120, 44))
	_join_go_btn.pressed.connect(_on_join_go_pressed)
	crow.add_child(_join_go_btn)

	_status = UiFactory.label("", 16)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(720, 96)
	vb.add_child(_status)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 16)
	vb.add_child(brow)
	_stop_btn = UiFactory.button("断开虚拟网", 16, Vector2(200, 48))
	_stop_btn.pressed.connect(_on_stop_pressed)
	_stop_btn.visible = false
	brow.add_child(_stop_btn)
	var close_btn := UiFactory.button("关 闭", 16, Vector2(200, 48))
	close_btn.pressed.connect(close)
	brow.add_child(close_btn)


func open() -> void:
	refresh()
	visible = true


func close() -> void:
	visible = false
	closed.emit()


## 刷新按钮/输入框状态(初次打开、操作完成、断开后都调)。
func refresh() -> void:
	# 剪贴板自动识别:朋友复制了码、打开面板这一下就预填(不用再手 Ctrl+V)
	if not _hosted and _code_edit.text.strip_edges() == "":
		var clip := ""
		if DisplayServer.clipboard_has():
			clip = DisplayServer.clipboard_get()
		if clip.begins_with(EasyTierLink.CODE_PREFIX):
			_code_edit.text = clip
	_host_btn.disabled = _busy
	_join_btn.disabled = _busy or _hosted
	_join_go_btn.disabled = _busy or _hosted
	_code_edit.editable = not _hosted
	_copy_btn.visible = _hosted
	_stop_btn.visible = EasyTierLink.is_active() or _hosted


# ── 房主 ───────────────────────────────────────────────────────────

func _on_host_pressed() -> void:
	if _busy:
		return
	if _hosted and EasyTierLink.is_active():
		_status.text = "虚拟网已在运行,邀请码在上面 ↓"
		return
	_busy = true
	refresh()
	_status.text = "正在开网(等待 Windows 管理员授权,请点「是」)…"
	var r: Dictionary = await EasyTierLink.host_start()
	_busy = false
	# ★ 空结果防护(P1 实测教训):协程中途崩掉时 await 回来的是 null,
	#   直接 .get() 会二次报错、面板永远停在"正在开网"。此处必须先验型。
	if r == null or typeof(r) != TYPE_DICTIONARY:
		push_error("OneClickNet: host_start 返回了空结果(见上一条脚本错误)")
		_status.text = "开网流程内部出错(空结果)——请把「输出」面板里最后一条红色错误发给开发者"
		refresh()
		return
	if not bool(r.get("ok", false)):
		_status.text = str(r.get("err", "开网失败"))
		refresh()
		return
	_hosted = true
	_code_edit.text = str(r["code"])
	_status.text = "虚拟网就绪(本机虚拟 IP:%s)。把邀请码发给朋友,然后直接建房即可;\n朋友加入后,「服务器地址」会自动帮你填好。" % str(r["ip"])
	refresh()
	net_ready.emit(str(r["ip"]), true)


# ── 朋友 ───────────────────────────────────────────────────────────

func _on_join_pressed() -> void:
	# 「我是朋友」= 聚焦粘贴框;真正动手在「加 入」
	var clip := ""
	if DisplayServer.clipboard_has():
		clip = DisplayServer.clipboard_get()
	if clip.begins_with(EasyTierLink.CODE_PREFIX):
		_code_edit.text = clip
	_status.text = "已把剪贴板里的邀请码填上(或手动粘贴),点「加 入」"
	_code_edit.grab_focus()


func _on_join_go_pressed() -> void:
	if _busy or _hosted:
		return
	var code := _code_edit.text.strip_edges()
	if code == "":
		_status.text = "先把房主发的邀请码粘贴进来"
		return
	_busy = true
	refresh()
	_status.text = "正在加入虚拟网(等待 Windows 管理员授权,请点「是」)…"
	var r: Dictionary = await EasyTierLink.join(code)
	_busy = false
	if r == null or typeof(r) != TYPE_DICTIONARY:   # 同 host 路径的空结果防护
		push_error("OneClickNet: join 返回了空结果(见上一条脚本错误)")
		_status.text = "加入流程内部出错(空结果)——请把「输出」面板里最后一条红色错误发给开发者"
		refresh()
		return
	if not bool(r.get("ok", false)):
		_status.text = str(r.get("err", "加入失败"))
		refresh()
		return
	_status.text = "已加入虚拟网(我的虚拟 IP:%s),「服务器地址」已自动填好,关掉本窗即可建房/进房。" % str(r["my_ip"])
	refresh()
	net_ready.emit(str(r["host_ip"]), false)


# ── 其它 ───────────────────────────────────────────────────────────

func _on_copy_pressed() -> void:
	if _code_edit.text != "":
		DisplayServer.clipboard_set(_code_edit.text)
		_status.text = "邀请码已复制,发给朋友即可(微信/QQ 直接粘贴)"

func _on_stop_pressed() -> void:
	EasyTierLink.stop()
	_hosted = false
	_status.text = "已断开虚拟网(朋友将连不上你;重新开网会生成新邀请码)"
	refresh()

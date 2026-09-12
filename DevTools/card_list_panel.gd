class_name CardListPanel
extends VBoxContainer

# 卡列表(编辑器左列):新建 / 删除(带确认)/ 选中。
# 数据读写经 CardStore;选中/增删通过信号通知装配根(card_editor.gd)接线。

signal card_selected(card: Dictionary)
signal list_changed

var card_type := CardSchema.TYPE_OPERATOR

var _list: ItemList = null
var _ids: Array[String] = []
var _selected_id := ""
var _delete_dialog: ConfirmationDialog = null


func _ready() -> void:
	custom_minimum_size = Vector2(380, 0)
	add_theme_constant_override("separation", 12)
	add_child(DevUIKit.label("卡列表", 26, Color(0.55, 0.95, 1.0)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	row.add_child(DevUIKit.button("＋ 新建", 20, _on_new_card))
	row.add_child(DevUIKit.button("删 除", 20, _on_delete_card))
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(360, 0)
	var pf := DevUIKit.font()
	if pf != null:
		_list.add_theme_font_override("font", pf)
		_list.add_theme_font_size_override("font_size", 20)
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)
	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.ok_button_text = "删除"
	_delete_dialog.cancel_button_text = "取消"
	_delete_dialog.confirmed.connect(_do_delete)
	add_child(_delete_dialog)


## 切换干员/武器页:清空选中并重载(选中第一张会经 card_selected 发出)
func set_type(type: String) -> void:
	card_type = type
	_selected_id = ""
	reload_list()


## 重载列表。keep_quiet=true 时保持当前选中且不发选择信号
## (表单自动保存后刷新条目名用,避免打断输入)
func reload_list(keep_quiet := false) -> void:
	_ids = CardStore.list_ids(card_type)
	_list.clear()
	var keep_idx := -1
	for i in _ids.size():
		var id := _ids[i]
		var card := CardStore.load_card(card_type, id)
		var display := str(card.get("name", ""))
		if display.is_empty():
			display = "(未命名)"
		var mark := "" if CardStore.has_portrait(card_type, id) else "  ⌀"
		_list.add_item("%s  (%s)%s" % [display, id, mark])
		if id == _selected_id:
			keep_idx = i
	if keep_idx >= 0:
		_list.select(keep_idx)
		if not keep_quiet:
			_emit_selection(keep_idx)
	elif not _ids.is_empty():
		_list.select(0)
		if not keep_quiet:
			_emit_selection(0)
	else:
		_selected_id = ""
		if not keep_quiet:
			card_selected.emit({})


func current_card() -> Dictionary:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		return {}
	return CardStore.load_card(card_type, _ids[sel[0]])


func _emit_selection(idx: int) -> void:
	_selected_id = _ids[idx]
	card_selected.emit(CardStore.load_card(card_type, _ids[idx]))


func _on_item_selected(idx: int) -> void:
	_emit_selection(idx)


func _on_new_card() -> void:
	var prefix := "op_" if card_type == CardSchema.TYPE_OPERATOR else ("pr_" if card_type == CardSchema.TYPE_PROP else "wp_")
	var n := 1
	while CardStore.list_ids(card_type).has("%s%d" % [prefix, n]):
		n += 1
	var id := "%s%d" % [prefix, n]
	var card := CardSchema.make_default(card_type, id)
	CardStore.save_card(card)
	_selected_id = id
	reload_list()
	list_changed.emit()


func _on_delete_card() -> void:
	if _selected_id.is_empty():
		return
	_delete_dialog.dialog_text = "确定删除卡「%s」?(JSON 与头像一并删除)" % _selected_id
	_delete_dialog.popup_centered()


func _do_delete() -> void:
	if _selected_id.is_empty():
		return
	CardStore.delete_card(card_type, _selected_id)
	_selected_id = ""
	reload_list()
	list_changed.emit()

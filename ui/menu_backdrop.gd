extends Control

# 主菜单复用实时背景，并在上方叠加遮罩以提高菜单文字的对比度。

const MAP := "res://maps/newfactory.cyrm"
const LIVE_BACKGROUND := preload("res://core/present/menu_background.gd")

var _live: ColorRect = null
var _dim: ColorRect = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if FileAccess.file_exists(MAP):
		_live = LIVE_BACKGROUND.new()
		_live.name = "LiveScene"
		_live.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_live)
		_live.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		# 地图读取失败时用底色保持菜单文字可读。
		push_warning("MenuBackdrop: 读不到菜单背景地图 %s" % MAP)
		var fallback := ColorRect.new()
		fallback.name = "Fallback"
		fallback.color = UiDesign.C_BG
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fallback)
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = UiDesign.C_MENU_DIM
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

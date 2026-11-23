extends Control

# 主菜单背景(从 main 的 ui/menu_backdrop.gd 迁移):main 版是「SubViewport + ParallaxBg + PostProcess」
# 的实时光影合成;那套依赖(MapFormat.load_subgrid_with_descs / MapFormat.load_bg_layers /
# TerrainAtlas.make_wall_tileset_for / ParallaxBg / PostProcess.bg_viewport/set_hour)在 siri 基座上不存在,
# 因此这里按同一职责做 **siri 可工作的版本**:
#   · 背景本体复用 siri 现有的实时菜单场景 core/present/menu_background.gd
#     (CyrmMap 地图数据 + 地形图集 + Daylight 昼夜 + menu_fisheye 相机漂移/鱼眼),不是烘焙贴图;
#   · 本文件只负责「铺满全屏 + 压暗层」,颜色引 UiDesign token,不写 Color 字面量、不写 StyleBox。
# ★ 不加 class_name:场景按脚本路径挂载(main 版同款约定);只依赖 core/present 与 UiDesign。

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
		# 兜底:地图读不到时至少给一块底色,菜单文字仍然可读(对应 main 的 %Bg 兜底职责)。
		push_warning("MenuBackdrop: 读不到菜单背景地图 %s" % MAP)
		var fallback := ColorRect.new()
		fallback.name = "Fallback"
		fallback.color = UiDesign.C_BG
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fallback)
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 压暗层:实时光影背景上的可读性保障(与 main 的 C_MENU_DIM 职责一致)。
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = UiDesign.C_MENU_DIM
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

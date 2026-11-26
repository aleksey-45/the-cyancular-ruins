extends RefCounted

# 布局间距以像素为单位。
const SP_1 := 4
const SP_2 := 8
const SP_3 := 12
const SP_4 := 16
const SP_5 := 24
const SP_6 := 32
const SP_7 := 40
const SP_8 := 48
const SP_9 := 64
const SP_10 := 80
# HUD 以视口边缘为锚点，边距取自此常量。
const MARGIN := 24
# 像素字体的基准字号为 16 像素。
const T_HUGE := 128
const T_H1 := 48
const T_H2 := 32
const T_BODY := 16
const T_LABEL := 16
const T_SUB := 28
const T_SMALL := 24
const T_H3 := 40
const BORDER_W := 2
const BORDER_W_DIM := 1

# UI 调色板。各页面使用这里定义的颜色。
const C_BG          := Color(0.039, 0.059, 0.094)
const C_SURFACE     := Color(0.071, 0.086, 0.118)
const C_ROW         := Color(0.086, 0.094, 0.110)
const C_FIELD       := Color(0.106, 0.118, 0.141)
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)
# 描边与页面背景、按钮填充色的对比度目标均为 3:1。
const C_BORDER      := Color(0.361, 0.439, 0.561)
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)
const C_ACCENT      := Color(0.349, 0.851, 0.902)
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_TEXT        := Color(0.878, 0.914, 0.949)
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)
# C_WHITE 是纯白色，C_TEXT 是偏冷的正文颜色。
const C_WHITE       := Color(1, 1, 1)
const C_WARN        := Color(0.950, 0.850, 0.550)

const C_MODE_TEAM   := Color(0.627, 0.549, 1.0)
const C_MODE_ROYALE := Color(0.910, 0.639, 0.239)

const C_HEADER     := Color("#1B242C")
const C_INNER      := Color("#1E2830")
const C_EDGE       := Color("#46545F")
const C_GOLD       := Color("#E0A94F")
const C_TEXT_MUTE  := Color("#6C7885")

const C_TRANSPARENT := Color(0, 0, 0, 0)

const C_GRACE       := Color(0.72, 0.62, 0.90)

const C_PLATE       := Color(0, 0, 0, 0.1)
# 主菜单背景遮罩色，用于提高菜单文字的对比度。
const C_MENU_DIM    := Color(0, 0, 0, 0.22)
# 当前选中的武器行使用比 C_PLATE 更深的底色。
const C_PLATE_DEEP  := Color(0, 0, 0, 0.28)

const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)

const C_SLOT_EMPTY  := Color(0.510, 0.600, 0.624, 0.5)
const C_SLOT_FILLED := Color(0.360, 0.620, 0.920, 0.5)
const C_SLOT_ACTIVE := Color(0.090, 0.300, 0.680, 0.5)


static func flat(fill: Color, border: Color, width: int, pad_x: float, pad_y: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	if width > 0:
		box.border_color = border
		box.set_border_width_all(width)
	box.content_margin_left = pad_x
	box.content_margin_right = pad_x
	box.content_margin_top = pad_y
	box.content_margin_bottom = pad_y
	return box


static func panel_box(border := true) -> StyleBoxFlat:
	return flat(C_SURFACE, C_BORDER, BORDER_W if border else 0, 28, 20)

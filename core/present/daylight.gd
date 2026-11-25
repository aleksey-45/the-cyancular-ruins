class_name Daylight
extends ColorRect

const DAY := 24 * 60
const NOON := DAY / 2
const PALETTE: Image = preload("res://core/present/daylight_palette.png")
const HORIZON := preload("res://core/present/sky_gradient.tres")

var overscan_y := 1.0
## X/Y 指向当前光源，Z 是太阳在地平线以上的高度。
var directional_light := Vector3(0, -1, 1)
## RGB 是日月颜色，Alpha 控制光源在地平线附近的淡入淡出。
var directional_color: Color

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

## 天顶色也是地形与角色的环境光。
func set_minute(minute: float) -> Color:
	var phase := fposmod(minute / DAY, 1.0)
	var column := phase * PALETTE.get_width()
	var left := floori(column)
	var right := (left + 1) % PALETTE.get_width()
	color = PALETTE.get_pixel(left, 0).lerp(PALETTE.get_pixel(right, 0), column - left)
	var direction := Vector2.DOWN.rotated(TAU * phase)
	var sun_height := maxf(-direction.y, 0.0)
	directional_color = Color("#fff0bd")
	if direction.y > 0.0:
		direction = -direction
		directional_color = Color("#637cbe")
	directional_light = Vector3(direction.x, direction.y, sun_height)
	directional_color.a = smoothstep(0.0, 0.15, -direction.y)
	queue_redraw()
	return color

func _draw() -> void:
	var height := HORIZON.get_height()
	var ramp := Rect2(0, (1.0 - overscan_y) * height * 0.5, 1, height * overscan_y)
	draw_texture_rect_region(HORIZON, Rect2(Vector2.ZERO, size), ramp, color - Color8(40, 40, 40, 0), false, false)

static func minute_at(seconds: float) -> float:
	return fposmod(6 * 60 + seconds * DAY / 120.0, DAY)

static func time_text(value: float) -> String:
	var minutes := floori(value)
	return "%02d:%02d" % [minutes / 60, minutes % 60]

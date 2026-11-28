class_name WorldDrawing
extends RefCounted

enum Pass { NORMAL, PLAYER_BODY, GLOW, MASK, FOREGROUND }
enum Mark { BOX, CIRCLE, POLYGON, LINE }

class Textures:
	var items: Array[Texture2D] = []
	var _indices: Dictionary[Texture2D, int] = {}

	func index(texture: Texture2D) -> int:
		if not _indices.has(texture):
			_indices[texture] = items.size()
			items.append(texture)
		return _indices[texture]

var textures: Textures
var data := {"minute": Daylight.NOON, "actors": 0, "eyes": [], "sprites": [], "lines": [],
	"marks": [], "overlay": [], "labels": [[], []], "bars": [], "prompts": [], "reload": []}

func _init(table: Textures) -> void:
	textures = table

static func diffuse(texture: Texture2D) -> Texture2D:
	return texture.diffuse_texture if texture is CanvasTexture else texture

func sprite(texture: Texture2D, region: Rect2, pose: Transform2D, color := Color.WHITE,
		style := Pass.NORMAL) -> void:
	if style == Pass.GLOW or style == Pass.MASK:
		texture = diffuse(texture)
	data.sprites.append([textures.index(texture), region, pose, color, style])

func line(points: PackedVector2Array, color: Color, width: float, overlay := false) -> void:
	if overlay:
		data.overlay.append([Mark.LINE, points, color, width])
	else:
		data.lines.append([points, color, width])

func rect(box: Rect2, color: Color, stroke := -1.0, overlay := true) -> void:
	var rows: Array = data.overlay if overlay else data.marks
	rows.append([Mark.BOX, box, color, stroke])

func circle(at: Vector2, radius: float, color: Color, overlay := false) -> void:
	var rows: Array = data.overlay if overlay else data.marks
	rows.append([Mark.CIRCLE, at, radius, color])

func polygon(points: PackedVector2Array, color: Color) -> void:
	data.marks.append([Mark.POLYGON, points, color])

func text_at(value: String, at: Vector2, color: Color, plate := false, outline := 0) -> void:
	data.labels[int(not plate)].append([value, at, color, plate, outline])

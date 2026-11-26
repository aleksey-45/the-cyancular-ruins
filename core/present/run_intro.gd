class_name RunIntro
extends RefCounted

enum Frame { TIME, WALLS, CAMERA, WATER, POST, DRAW }

const PATH := "user://last_run_intro.dat"
const FORMAT := 1
const MAX_FRAMES := 300
const HOLD := 0.1
const BODY_SECONDS := 2.8
const AGE_SCALE := 0.5

var map: Dictionary
var frames: Array[Array] = []
var texture_paths: Array[String] = []
var walls := PackedByteArray()
var _texture_ids: Dictionary[Texture2D, int] = {}
var _walls_shared := false
var _map_bytes := PackedByteArray()

func _init(document: Dictionary) -> void:
	map = document
	walls.resize((map.size.x * map.size.y + 7) >> 3)

func patch_walls(changes: Dictionary) -> void:
	if changes.is_empty():
		return
	if _walls_shared:
		walls = walls.duplicate()
		_walls_shared = false
	for index: int in changes:
		var flag := 1 << (index & 7)
		if changes[index]:
			walls[index >> 3] &= ~flag
		else:
			walls[index >> 3] |= flag

func texture_index(texture: Texture2D) -> int:
	if not _texture_ids.has(texture):
		_texture_ids[texture] = texture_paths.size()
		texture_paths.append(texture.resource_path)
	return _texture_ids[texture]

func append(frame: Array) -> void:
	var time: float = frame[Frame.TIME]
	_walls_shared = true
	if not frames.is_empty() and frames[-1][Frame.TIME] == time:
		frames[-1] = frame
		return
	frames.append(frame)
	if frames.size() <= MAX_FRAMES:
		return
	var crowded := 1
	var shortest := INF
	for i in range(1, frames.size() - 1):
		var before: float = frames[i - 1][Frame.TIME]
		var after: float = frames[i + 1][Frame.TIME]
		# 比较删去该帧后，相邻两帧在倒放时间轴上的间隔。
		var gap := (after - before) / (AGE_SCALE + time - after)
		if gap < shortest:
			shortest = gap
			crowded = i
	frames.remove_at(crowded)

func duration() -> float:
	return minf(frames[-1][Frame.TIME], BODY_SECONDS) + 2.0 * HOLD

func frame_index(elapsed: float) -> int:
	var index := frames.size() - 1
	if elapsed <= HOLD:
		return index
	var span: float = frames[-1][Frame.TIME]
	var body := minf(span, BODY_SECONDS)
	if elapsed >= HOLD + body:
		return 0
	var progress := (elapsed - HOLD) / body
	var target := span - AGE_SCALE * (pow(1.0 + span / AGE_SCALE, progress) - 1.0)
	while index > 0 and target < (frames[index][Frame.TIME] + frames[index - 1][Frame.TIME]) * 0.5:
		index -= 1
	return index

func load_textures() -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	for path in texture_paths:
		textures.append(load(path))
	return textures

func save() -> void:
	if _map_bytes.is_empty():
		_map_bytes = CyrmMap.to_bytes(map)
	var masks: Array[PackedByteArray] = []
	var mask_ids: Dictionary[PackedByteArray, int] = {}
	var saved_frames: Array[Array] = []
	for frame in frames:
		var mask: PackedByteArray = frame[Frame.WALLS]
		if not mask_ids.has(mask):
			mask_ids[mask] = masks.size()
			masks.append(mask)
		var saved := frame.duplicate()
		saved[Frame.WALLS] = mask_ids[mask]
		saved_frames.append(saved)
	var temporary := "%s.%d.tmp" % [PATH, OS.get_process_id()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入单人片头存档")
		return
	var written := file.store_32(FORMAT) and file.store_var([_map_bytes, texture_paths, masks, saved_frames])
	file.close()
	if not written or DirAccess.rename_absolute(temporary, PATH) != OK:
		DirAccess.remove_absolute(temporary)
		push_warning("无法写入单人片头存档")

static func load_pending() -> RunIntro:
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null or file.get_32() != FORMAT:
		return null
	var data: Variant = file.get_var()
	if not data is Array or data.size() != 4:
		return null
	var document := CyrmMap.from_bytes(data[0])
	if document.is_empty() or data[3].is_empty():
		return null
	var intro := RunIntro.new(document)
	intro.texture_paths.assign(data[1])
	intro.frames.assign(data[3])
	for frame in intro.frames:
		frame[Frame.WALLS] = data[2][frame[Frame.WALLS]]
	return intro

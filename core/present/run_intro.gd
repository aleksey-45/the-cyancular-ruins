class_name RunIntro
extends RefCounted

const PATH := "user://last_run_intro.dat"
const FORMAT := 3
const MAX_FRAMES := 300
const HOLD := 0.1
const BODY_SECONDS := 2.8
const AGE_SCALE := 0.5

var map: Dictionary
var textures: Array[Texture2D]
var frames: Array[DrawFrame] = []

func _init(document: Dictionary, table: Array[Texture2D]) -> void:
	map = document
	textures = table

func append(frame: DrawFrame) -> void:
	frames.append(frame)
	if frames.size() <= MAX_FRAMES: return
	var crowded := 1
	var shortest := INF
	for i in range(1, frames.size() - 1):
		var before: float = frames[i - 1].time
		var after: float = frames[i + 1].time
		var gap: float = (after - before) / (AGE_SCALE + frame.time - after)
		if gap < shortest:
			shortest = gap
			crowded = i
	frames.remove_at(crowded)

func duration() -> float:
	return minf(frames[-1].time - frames[0].time, BODY_SECONDS) + 2.0 * HOLD

func frame_at(elapsed: float) -> DrawFrame:
	if elapsed <= HOLD: return frames[-1]
	var span := frames[-1].time - frames[0].time
	var body := minf(span, BODY_SECONDS)
	if elapsed >= HOLD + body: return frames[0]
	var progress := (elapsed - HOLD) / body
	var target := frames[-1].time - AGE_SCALE * (pow(1.0 + span / AGE_SCALE, progress) - 1.0)
	var i := frames.size() - 1
	while i > 0 and target < (frames[i].time + frames[i - 1].time) * 0.5:
		i -= 1
	return frames[i]

func save(path: String) -> void:
	var masks: Array[PackedByteArray] = []
	var mask_ids: Dictionary[PackedByteArray, int] = {}
	var rows: Array[Array] = []
	for frame in frames:
		var mask: PackedByteArray = frame.walls
		if not mask_ids.has(mask):
			mask_ids[mask] = masks.size()
			masks.append(mask)
		rows.append([frame.time, frame.camera, mask_ids[mask], frame.water, frame.world, frame.hud, frame.post])
	var paths := textures.map(func(texture: Texture2D) -> String: return texture.resource_path)
	var error := AtomicFile.save(path, func(file: FileAccess) -> bool:
		return file.store_32(FORMAT) and file.store_var([CyrmMap.to_bytes(map), paths, masks, rows]))
	if error != OK: push_warning("无法写入单人片头存档")

static func load_pending(path: String) -> RunIntro:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_32() != FORMAT: return null
	var data: Array = file.get_var()
	var table: Array[Texture2D] = []
	for texture_path: String in data[1]:
		table.append(load(texture_path))
	var intro := RunIntro.new(CyrmMap.from_bytes(data[0]), table)
	for row: Array in data[3]:
		intro.frames.append(DrawFrame.new(row[0], row[1], data[2][row[2]], row[3], row[4], row[5], row[6]))
	return intro

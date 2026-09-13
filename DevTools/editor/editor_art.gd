class_name EditorArt
extends RefCounted

# 美术槽管线(画师优先):每槽一文件;状态=人工已上传 / AI 占位 / 缺失。
# - 上传:任意 png/webp/jpg → 统一转存为槽位 png(魔数校验);
# - 导出占位:把当前槽位图导出到任意路径(画师在它上面改);
# - AI 占位:卡面槽走 gen_portrait 程序化生成(贴近原作风格);其余槽复制卡面图作底稿。
# 约定:游戏侧优先读人工素材;AI 占位文件与人工文件同名,靠「来源标记」区分展示
# (<id>__<slot>.meta 里记 source=human|ai,上传即 human,生成即 ai)。

const MAGIC_PNG := "89504e47"
const MAGIC_WEBP := "52494646"
const MAGIC_JPG := "ffd8ff"


static func slot_abs_path(type: String, id: String, slot_key: String) -> String:
	var p := EditorSchema.art_path(type, id, slot_key)
	return "" if p == "" else ProjectSettings.globalize_path(p)


static func meta_path(abs_png: String) -> String:
	return abs_png + ".meta"


## 状态:"human" 人工 / "ai" 占位 / "" 缺失
static func slot_status(type: String, id: String, slot_key: String) -> String:
	var p := slot_abs_path(type, id, slot_key)
	if p == "" or not FileAccess.file_exists(p):
		return ""
	var m := meta_path(p)
	if FileAccess.file_exists(m):
		var txt := FileAccess.get_file_as_string(m)
		if txt.contains("human"):
			return "human"
	return "ai"


static func _write_meta(abs_png: String, source: String) -> void:
	var f := FileAccess.open(meta_path(abs_png), FileAccess.WRITE)
	if f != null:
		f.store_string("source=%s\nupdated=%s\n" % [source, Time.get_datetime_string_from_system()])
		f.close()


## 上传:把 src 转存为槽位 png。返回错误串(空=成功)。
static func import_file(type: String, id: String, slot_key: String, src_abs: String) -> String:
	var dst := slot_abs_path(type, id, slot_key)
	if dst == "":
		return "未知美术槽:%s" % slot_key
	var ext := src_abs.get_extension().to_lower()
	if not ext in ["png", "webp", "jpg", "jpeg"]:
		return "不支持的格式 .%s(请用 png/webp/jpg)" % ext
	var head := FileAccess.get_file_as_string(src_abs).left(4) if FileAccess.file_exists(src_abs) else ""
	var bytes := FileAccess.get_file_as_bytes(src_abs)
	if bytes.is_empty():
		return "读不到源文件:%s" % src_abs
	var hex := bytes.slice(0, 4).hex_encode()
	var png_ok := hex.begins_with(MAGIC_PNG)
	var webp_ok := hex.begins_with(MAGIC_WEBP)
	var jpg_ok := hex.begins_with(MAGIC_JPG)
	if not (png_ok or webp_ok or jpg_ok):
		return "文件不像图片(png/webp/jpg 魔数不符)"
	var img := Image.load_from_file(src_abs)
	if img == null:
		return "图片解码失败:%s" % src_abs
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var err := img.save_png(dst)
	if err != OK:
		return "保存失败(err=%d)" % err
	_write_meta(dst, "human")
	return ""


## 删除槽位文件(含 meta)
static func clear_slot(type: String, id: String, slot_key: String) -> void:
	var p := slot_abs_path(type, id, slot_key)
	if p != "" and FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	if p != "" and FileAccess.file_exists(meta_path(p)):
		DirAccess.remove_absolute(meta_path(p))


## 把槽位当前图导出(画师改图起点)。返回错误串。
static func export_slot(type: String, id: String, slot_key: String, dst_abs: String) -> String:
	var p := slot_abs_path(type, id, slot_key)
	if p == "" or not FileAccess.file_exists(p):
		return "该槽位还没有图"
	var img := Image.load_from_file(p)
	if img == null:
		return "槽位图解码失败"
	var err := img.save_png(dst_abs)
	return "" if err == OK else "导出失败(err=%d)" % err


## AI 占位:卡面槽调 gen_portrait(程序化像素画,贴近原作风格);其余槽复制卡面为底稿。
## 返回错误串;阻塞式(生成器秒级完成)。
static func make_ai_placeholder(type: String, id: String, slot_key: String) -> String:
	var dst := slot_abs_path(type, id, slot_key)
	if dst == "":
		return "未知美术槽"
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	# 通用像素占位:id 播种色调 + 深色描边 + 网格纹理(贴近原作像素风;正式版由画师上传替换)。
	# 旧 gen_portrait 按已知卡 id 硬编码分支,不适合任意新卡,故此处直接程序化绘制。
	if slot_key != "card":
		# 其余槽:以卡面图为底稿(画师在其上绘制);没有卡面则画纯色占位
		var base := slot_abs_path(type, id, "card")
		var img: Image = null
		if FileAccess.file_exists(base):
			img = Image.load_from_file(base)
		if img == null:
			img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.2, 0.3, 0.35))
		var err2 := img.save_png(dst)
		if err2 == OK:
			_write_meta(dst, "ai")
			return ""
		return "底稿保存失败(err=%d)" % err2
	var img := _generic_badge(id)
	var err := img.save_png(dst)
	if err != OK:
		return "占位保存失败(err=%d)" % err
	_write_meta(dst, "ai")
	return ""


## id 播种的通用像素徽章: deterministic,风格向原作靠拢(暗底/青蓝系/深描边/网格)
static func _generic_badge(id: String) -> Image:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var seed_n := id.hash()
	var base := Color.from_hsv(float(seed_n % 360) / 360.0, 0.45, 0.55, 1.0)
	var dark := base.darkened(0.55)
	var light := base.lightened(0.35)
	for y in range(size):
		for x in range(size):
			var c := base
			if x == 0 or y == 0 or x == size - 1 or y == size - 1:
				c = Color(0.08, 0.1, 0.12)   # 深描边
			elif (x + y) % 16 < 8:
				c = dark
			if (x / 8 + y / 8) % 3 == 0:
				c = light
			img.set_pixel(x, y, c)
	# 中央 id 首字母像素块(粗略 5x5 计数条,标识不同 id)
	var bars := 5
	for i in range(bars):
		var h := 8 + (seed_n >> (i * 3)) % 20
		for y in range(h):
			for x in range(4):
				img.set_pixel(12 + i * 8 + x, size - 12 - y, light)
	return img

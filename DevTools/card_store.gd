class_name CardStore
extends RefCounted

# 卡的磁盘读写(DevTools):一卡一对文件 <id>.json + <id>.png(头像,agent 生成,编辑器只读)。
# 职责边界:只懂「卡在磁盘怎么放」;字段定义/校验在 card_schema.gd。
# 只在开发分支的工程目录里跑(res:// 可写);打包已被 export exclude_filter 排除。

const ROOT := "res://DevTools/cards"
const STATE_PATH := ROOT + "/.state.json"   # 游戏侧现状标记(骨架是否已建等),决定提示词 FIRST/NEXT 分派


static func cards_dir(type: String) -> String:
	if type == CardSchema.TYPE_OPERATOR:
		return ROOT + "/operators"
	if type == CardSchema.TYPE_PROP:
		return ROOT + "/props"
	return ROOT + "/weapons"


static func card_path(type: String, id: String) -> String:
	return "%s/%s.json" % [cards_dir(type), id]


static func portrait_path(type: String, id: String) -> String:
	return "%s/%s.png" % [cards_dir(type), id]


## 导入手绘/外部素材:把本地图片文件复制成 <id>.png 一类卡内头像(编辑器"上传自己画的素材"入口)。
## 返回错误串(空=成功)。支持 png/webp/jpg(Image.load_from_file 同源解码)。
static func import_portrait(type: String, id: String, src_abs: String) -> String:
	var ext := src_abs.get_extension().to_lower()
	if not ext in ["png", "webp", "jpg", "jpeg"]:
		return "不支持的格式 .%s(请用 png/webp/jpg)" % ext
	var fb := FileAccess.open(src_abs, FileAccess.READ)
	if fb == null:
		return "读不到源文件:%s" % src_abs
	var bytes := fb.get_buffer(fb.get_length())
	fb.close()
	# 简单魔数校验,防止把非图片当素材
	var ok_magic := (
		(bytes.size() > 8 and bytes[0] == 0x89 and bytes[1] == 0x50)
		or (bytes.size() > 12 and bytes[0] == 0x52 and bytes[1] == 0x49)
		or (bytes.size() > 3 and bytes[0] == 0xFF and bytes[1] == 0xD8)
	)
	if not ok_magic:
		return "文件不像图片(png/webp/jpg 魔数不符)"
	var dst := portrait_path(type, id) if ext == "png" else "%s.%s" % [portrait_path(type, id).trim_suffix(".png"), ext]
	_ensure_dir(cards_dir(type))
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return "写不进去:%s" % dst
	f.store_buffer(bytes)
	f.close()
	return ""


static func has_portrait(type: String, id: String) -> bool:
	return FileAccess.file_exists(portrait_path(type, id))


## 卡 id 清单(文件名即 id,排序返回)
static func list_ids(type: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(cards_dir(type))
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(f.trim_suffix(".json"))
	out.sort()
	return out


## 读卡(缺文件/JSON 坏 → 空字典 + push;读入后补全缺失可选字段)
static func load_card(type: String, id: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(card_path(type, id))
	if text.is_empty():
		push_warning("CardStore: 读不到 %s" % card_path(type, id))
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("CardStore: %s JSON 非法" % card_path(type, id))
		return {}
	return CardSchema.apply_defaults(parsed)


## 写卡:先校验;通过则 rev+1、盖 updated_at 时间戳,再落盘。返回错误列表(空=成功)
static func save_card(card: Dictionary, bump_rev := true) -> Array[String]:
	var errs := CardSchema.validate(card)
	if not errs.is_empty():
		return errs
	if bump_rev:
		card["rev"] = int(card.get("rev", 1)) + 1
	card["updated_at"] = Time.get_datetime_string_from_system()
	_ensure_dir(cards_dir(str(card["card_type"])))
	var path := card_path(str(card["card_type"]), str(card["id"]))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ["写文件失败:%s" % path]
	f.store_string(JSON.stringify(card, "\t"))
	f.close()
	return []


static func delete_card(type: String, id: String) -> void:
	var dir := DirAccess.open(cards_dir(type))
	if dir == null:
		return
	if dir.file_exists(id + ".json"):
		dir.remove(id + ".json")
	if dir.file_exists(id + ".png"):
		dir.remove(id + ".png")


## 头像纹理:存在 <id>.png → ImageTexture(不走 res:// 资源系统,避开新生成 PNG 无 .import);
## 没有/解码失败 → null(调用方回落占位图)
static func load_portrait_texture(type: String, id: String) -> ImageTexture:
	if not has_portrait(type, id):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(portrait_path(type, id)))
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


# ── 游戏侧现状标记(.state.json,提交进仓库;agent 施工完成时由人勾/工具写)──

static func load_state() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func save_state(state: Dictionary) -> void:
	_ensure_dir(ROOT)
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state, "\t"))
		f.close()


## FileAccess 不会自动建父目录,写盘前确保目录存在
static func _ensure_dir(res_dir: String) -> void:
	if DirAccess.open(res_dir) == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(res_dir))

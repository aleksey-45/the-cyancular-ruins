class_name PortraitView
extends VBoxContainer

# 头像页(编辑器右列):干员头像 / 武器剪影展示。
# 有 <id>.png(agent 程序化生成后落盘)显示真图;没有显示以 id 为种子的占位徽章。
# 不走 res:// 资源系统(新生成 PNG 没有 .import),用 Image.load_from_file 直读。

var _card: Dictionary = {}
var _rect: TextureRect = null
var _status: Label = null


func _ready() -> void:
	custom_minimum_size = Vector2(380, 0)
	add_theme_constant_override("separation", 12)
	add_child(DevUIKit.label("头像 / 剪影", 26, Color(0.55, 0.95, 1.0)))
	_rect = TextureRect.new()
	_rect.custom_minimum_size = Vector2(320, 320)
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_rect)
	_status = DevUIKit.label("", 18, Color(0.75, 0.8, 0.85))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(360, 0)
	add_child(_status)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	row.add_child(DevUIKit.button("刷新头像", 20, func() -> void: set_card(_card)))
	row.add_child(DevUIKit.button("导入手绘素材…", 20, _on_import_pressed))
	row.add_child(DevUIKit.button("删除素材", 20, _on_delete_pressed))
	row.add_child(DevUIKit.button("重新生成占位", 20, func() -> void:
		if _card.is_empty():
			return
		_rect.texture = make_placeholder(str(_card.get("card_type", "")), str(_card.get("id", "")))
		_status.text = "占位图(以 id 为种子的程序化徽章)。发送 agent 施工后会生成真实像素画,再点「刷新头像」"))
	set_card({})


var _dialog: FileDialog = null

func _on_delete_pressed() -> void:
	if _card.is_empty():
		return
	var dir := DirAccess.open(CardStore.cards_dir(str(_card.get("card_type", ""))))
	if dir != null:
		for ext in ["png", "webp", "jpg", "jpeg"]:
			var p: String = str(_card.get("id", "")) + "." + str(ext)
			if dir.file_exists(p):
				dir.remove(p)
	set_card(_card)

func _on_import_pressed() -> void:
	if _card.is_empty():
		_status.text = "先选中一张卡再导入素材"
		return
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.filters = ["*.png ; PNG 图片", "*.webp ; WebP 图片", "*.jpg ; JPEG 图片"]
		_dialog.file_selected.connect(_on_import_selected)
		add_child(_dialog)
	_dialog.popup_centered(Vector2i(900, 600))


func _on_import_selected(path: String) -> void:
	if _card.is_empty():
		return
	var err := CardStore.import_portrait(str(_card.get("card_type", "")), str(_card.get("id", "")), path)
	if err != "":
		_status.text = "导入失败:" + err
		return
	_status.text = "已导入手绘素材:%s(对局内实体美术同样走这个入口;AI 生成素材仅作兜底)" % path.get_file()
	set_card(_card)


## 切换展示的卡(空字典 = 未选中);每次都会重读磁盘上的 PNG(施工完成后点刷新即可见)
func set_card(card: Dictionary) -> void:
	_card = card
	if card.is_empty():
		_rect.texture = null
		_status.text = "未选中卡"
		return
	var type := str(card.get("card_type", ""))
	var id := str(card.get("id", ""))
	var tex := CardStore.load_portrait_texture(type, id)
	if tex != null:
		_rect.texture = tex
		_status.text = "%s.png(agent 已生成)" % id
	else:
		_rect.texture = make_placeholder(type, id)
		_status.text = "尚无头像,显示占位图。发送 agent 施工后会按外貌描述生成像素画,届时点「刷新头像」"


## 占位徽章:以 seed_text 为种子的镜像对称像素块(同一张卡恒定同一张占位图),
## 16× 最近邻放大 —— 项目程序化纹理范式(参考 minimap.gd / explosion.gd 的 set_pixel 画法)。
static func make_placeholder(kind: String, seed_text: String) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind + "/" + seed_text)
	var w := 12 if kind == CardSchema.TYPE_OPERATOR else 16
	var h := 12
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var base := Color.from_hsv(rng.randf(), 0.45, 0.85)
	for y in h:
		for x in ceili(w / 2.0):
			if rng.randf() < 0.45:
				var c := base.lightened(rng.randf() * 0.35)
				c.a = 1.0
				img.set_pixel(x, y, c)
				img.set_pixel(w - 1 - x, y, c)
	img.resize(w * 16, h * 16, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)

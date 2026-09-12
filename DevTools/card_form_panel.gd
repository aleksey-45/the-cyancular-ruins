class_name CardFormPanel
extends ScrollContainer

# 表单(编辑器中列):干员/武器两套字段;任何改动防抖 0.3s 自动保存。
# 校验不过(如名称还空着)→ save_failed 信号上报装配根显示,不打断输入。
# 字段定义以 card_schema.gd 为准;本面板只负责 控件 ↔ 卡字典 的双向搬运。

signal card_saved(card: Dictionary)
signal save_failed(errs: Array[String])

const KEY_LABELS := ["Z (skill_1)", "X (skill_2)", "C (skill_3)"]
const KIND_LABELS := ["gun 枪械", "melee 冷兵器", "thrown 爆炸投掷", "special 其他"]
const PROP_KIND_LABELS := ["knockback 击退炮", "attraction 吸力炮", "smoke 烟雾弹"]
const TIER_LABELS := ["light 轻", "medium 中", "heavy 重"]
const TEXMODE_LABELS := ["tint 色相染色", "sheet 五姿态图集"]
const DEBOUNCE := 0.3

var card_type := CardSchema.TYPE_OPERATOR

var _card: Dictionary = {}
var _loading := false          # set_card 回填期间抑制改动信号
var _save_seq := 0             # 防抖:只有最新一次改动的计时器会真正保存
var _op_box: VBoxContainer = null
var _wp_box: VBoxContainer = null
var _prop_box: VBoxContainer = null
var _f_op: Dictionary = {}     # 字段 key → 控件
var _row_op: Dictionary = {}   # 字段 key → 所在行(隐藏整行用)
var _f_wp: Dictionary = {}
var _row_wp: Dictionary = {}
var _f_prop: Dictionary = {}
var _row_prop: Dictionary = {}
var _skill_rows: Array = []    # [{root, name, key, cooldown, desc}]


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 10)
	add_child(inner)
	_op_box = VBoxContainer.new()
	_op_box.add_theme_constant_override("separation", 10)
	inner.add_child(_op_box)
	_build_operator(_op_box)
	_wp_box = VBoxContainer.new()
	_wp_box.add_theme_constant_override("separation", 10)
	inner.add_child(_wp_box)
	_build_weapon(_wp_box)
	_prop_box = VBoxContainer.new()
	_prop_box.add_theme_constant_override("separation", 10)
	inner.add_child(_prop_box)
	_build_prop(_prop_box)


## 装配根接线:列表选中变化 → 整卡回填
func set_card(card: Dictionary) -> void:
	_loading = true
	_skill_rows.clear()
	_card = CardSchema.apply_defaults(card)
	card_type = str(_card.get("card_type", card_type))
	var is_op := card_type == CardSchema.TYPE_OPERATOR
	var is_prop := card_type == CardSchema.TYPE_PROP
	_op_box.visible = is_op and not card.is_empty()
	_prop_box.visible = is_prop and not card.is_empty()
	_wp_box.visible = not is_op and not is_prop and not card.is_empty()
	if _op_box.visible:
		_fill_operator()
	elif _prop_box.visible:
		_fill_prop()
	elif _wp_box.visible:
		_fill_weapon()
	_loading = false


# ── 小控件工厂(建好即登记进 _f_*,统一接改动信号)──

func _row(parent: Control, caption: String, w: Control, key := "") -> Control:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	r.add_child(DevUIKit.label(caption, 20))
	r.add_child(w)
	parent.add_child(r)
	if key != "":
		_row_of(parent)[key] = r
	return r


func _row_of(parent: Control) -> Dictionary:
	if parent == _op_box:
		return _row_op
	if parent == _prop_box:
		return _row_prop
	return _row_wp


func _fields(parent: Control) -> Dictionary:
	if parent == _op_box:
		return _f_op
	if parent == _prop_box:
		return _f_prop
	return _f_wp


func _line(parent: Control, key: String, placeholder: String) -> LineEdit:
	var e := DevUIKit.line_edit(placeholder, "")
	e.custom_minimum_size = Vector2(420, 44)
	e.text_changed.connect(_on_changed)
	_fields(parent)[key] = e
	return e


func _spin(parent: Control, key: String, mini: float, maxi: float, step: float, suffix := "") -> SpinBox:
	var s := DevUIKit.spin_box(mini, maxi, step, mini)
	if suffix != "":
		s.suffix = suffix
	s.value_changed.connect(_on_changed)
	_fields(parent)[key] = s
	return s


func _text(parent: Control, key: String, placeholder: String, height: float) -> TextEdit:
	var e := DevUIKit.text_edit(placeholder, "")
	e.custom_minimum_size = Vector2(760, height)
	e.text_changed.connect(_on_changed)
	_fields(parent)[key] = e
	return e


func _opt(parent: Control, key: String, labels: Array) -> OptionButton:
	var o := DevUIKit.option(labels, 0)
	o.item_selected.connect(_on_changed)
	_fields(parent)[key] = o
	return o


func _chk(parent: Control, key: String, caption: String) -> CheckButton:
	var c := DevUIKit.check(caption, false)
	c.toggled.connect(_on_changed)
	_fields(parent)[key] = c
	return c


# ── 干员表单 ──
func _build_operator(box: VBoxContainer) -> void:
	box.add_child(DevUIKit.label("干员卡", 26, Color(0.55, 0.95, 1.0)))
	_row(box, "名称", _line(box, "name", "干员名称"))
	_row(box, "血量", _spin(box, "max_hp", 1, 999, 1, "HP"))
	box.add_child(DevUIKit.label("外貌描述(像素头像按此生成:体型 / 配色 / 装备 / 气质…)", 20, Color(0.75, 0.8, 0.85)))
	box.add_child(_text(box, "appearance", "例:矮壮的雪地斥候,藏青连帽斗篷,护目镜反光,背着信号枪…", 120))
	box.add_child(DevUIKit.label("技能(≤3 条,默认键位 Z / X / C)", 22, Color(0.55, 0.95, 1.0)))
	var sk := VBoxContainer.new()
	sk.add_theme_constant_override("separation", 8)
	box.add_child(sk)
	_f_op["skills_box"] = sk
	_f_op["add_skill"] = DevUIKit.button("＋ 添加技能", 18, func() -> void:
		_add_skill_row()
		_update_add_skill_btn()
		_on_changed())
	box.add_child(_f_op["add_skill"])
	box.add_child(DevUIKit.label("干员故事", 22, Color(0.55, 0.95, 1.0)))
	box.add_child(_text(box, "story", "背景 / 来历 / 性格…", 120))
	_row(box, "外貌方案", _opt(box, "texture_mode", TEXMODE_LABELS))
	_row(box, "色相染色(°)", _line(box, "tint", "0~360,留空=不染色(仅 tint 方案)"))
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 12)
	box.add_child(stats)
	stats.add_child(DevUIKit.label("移速×", 20))
	stats.add_child(_spin(box, "move_speed_mult", 0.5, 2.0, 0.05))
	stats.add_child(DevUIKit.label("跳跃×", 20))
	stats.add_child(_spin(box, "jump_mult", 0.5, 2.0, 0.05))
	stats.add_child(DevUIKit.label("护甲", 20))
	stats.add_child(_spin(box, "armor", 0, 10, 1))


func _add_skill_row(data: Dictionary = {}) -> void:
	if _skill_rows.size() >= CardSchema.MAX_SKILLS:
		return
	var box: VBoxContainer = _f_op["skills_box"]
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	root.add_child(line)
	var row := {"root": root}
	line.add_child(DevUIKit.label("名称", 18))
	row["name"] = DevUIKit.line_edit("技能名", str(data.get("name", "")))
	row["name"].custom_minimum_size = Vector2(180, 40)
	row["name"].text_changed.connect(_on_changed)
	line.add_child(row["name"])
	line.add_child(DevUIKit.label("键位", 18))
	row["key"] = DevUIKit.option(KEY_LABELS, maxi(0, CardSchema.SKILL_KEYS.find(str(data.get("key", "skill_1")))))
	row["key"].item_selected.connect(_on_changed)
	line.add_child(row["key"])
	line.add_child(DevUIKit.label("冷却", 18))
	row["cooldown"] = DevUIKit.spin_box(0, 300, 0.5, float(data.get("cooldown", 10.0)))
	row["cooldown"].suffix = "s"
	row["cooldown"].value_changed.connect(_on_changed)
	line.add_child(row["cooldown"])
	var del := DevUIKit.button("×", 18, func() -> void:
		_skill_rows.erase(row)
		root.queue_free()
		_update_add_skill_btn()
		_on_changed())
	line.add_child(del)
	root.add_child(DevUIKit.label("描述(agent 将按此实现技能行为)", 18, Color(0.75, 0.8, 0.85)))
	row["desc"] = DevUIKit.text_edit("例:向前方突进一小段,途中无敌,撞到敌人造成轻击退", str(data.get("desc", "")))
	row["desc"].custom_minimum_size = Vector2(760, 72)
	row["desc"].text_changed.connect(_on_changed)
	root.add_child(row["desc"])
	box.add_child(root)
	_skill_rows.append(row)


func _update_add_skill_btn() -> void:
	(_f_op["add_skill"] as Button).disabled = _skill_rows.size() >= CardSchema.MAX_SKILLS


func _fill_operator() -> void:
	for row in _skill_rows:
		(row["root"] as Control).queue_free()
	_skill_rows.clear()
	_f_op["name"].text = str(_card.get("name", ""))
	_f_op["max_hp"].value = float(_card.get("max_hp", 80))
	_f_op["appearance"].text = str(_card.get("appearance", ""))
	_f_op["story"].text = str(_card.get("story", ""))
	_f_op["texture_mode"].selected = maxi(0, CardSchema.TEXTURE_MODES.find(str(_card.get("texture_mode", "tint"))))
	_f_op["tint"].text = str(_card.get("tint", ""))
	for s in _card.get("skills", []):
		_add_skill_row(s)
	_update_add_skill_btn()
	var stats: Dictionary = _card["stats"]
	_f_op["move_speed_mult"].value = float(stats.get("move_speed_mult", 1.0))
	_f_op["jump_mult"].value = float(stats.get("jump_mult", 1.0))
	_f_op["armor"].value = float(stats.get("armor", 0))


# ── 武器表单 ──
func _build_weapon(box: VBoxContainer) -> void:
	box.add_child(DevUIKit.label("武器卡", 26, Color(0.55, 0.95, 1.0)))
	_row(box, "名称", _line(box, "name", "武器名称"))
	var kind := _opt(box, "kind", KIND_LABELS)
	_row(box, "性质", kind)
	kind.item_selected.connect(func(_i: int) -> void: _apply_kind_visibility())
	box.add_child(DevUIKit.label("外貌描述(剪影图按此生成:形制 / 长度 / 特征细节…)", 20, Color(0.75, 0.8, 0.85)))
	box.add_child(_text(box, "appearance", "例:柴刀状短弯刀,刀背锯齿,缠绳握柄…", 96))
	_row(box, "攻击间隔", _spin(box, "attack_interval", 0.05, 10.0, 0.05, "s"))
	_row(box, "弹夹容量", _spin(box, "mag_size", 0, 250, 1, "(0=无弹夹)"))
	_row(box, "换弹时间", _spin(box, "reload_time", 0.0, 10.0, 0.1, "s"))
	_row(box, "伤害", _spin(box, "damage", 1, 200, 1))
	_row(box, "击退力度", _spin(box, "impact", 0, 3000, 10))
	_row(box, "分级", _opt(box, "tier", TIER_LABELS))
	_row(box, "全自动", _chk(box, "full_auto", "按住连发"))
	_row(box, "重瞄", _chk(box, "heavy_aim", "按住激光预瞄,松开发射"))
	_row(box, "注册槽位", _spin(box, "slot", 0, 9, 1, "(0=纯设计稿,不注册)"))
	box.add_child(DevUIKit.label("弹道(近战类不适用)", 20, Color(0.75, 0.8, 0.85)))
	_row(box, "弹速", _spin(box, "bullet_speed", 100, 4000, 50, "px/s"))
	_row(box, "射程", _spin(box, "bullet_range", 50, 3000, 50, "px"))
	_row(box, "弹丸数", _spin(box, "pellet_count", 1, 24, 1))
	_row(box, "散布半角", _spin(box, "spread_deg", 0, 45, 0.5, "°"))
	_row(box, "弹体重力×", _spin(box, "bullet_gravity", 0, 1, 0.05))
	box.add_child(DevUIKit.label("性质参数", 20, Color(0.75, 0.8, 0.85)))
	_row(box, "近战范围", _spin(box, "kp_range", 20, 400, 5, "px"))
	_row(box, "挥砍弧角", _spin(box, "kp_arc", 30, 360, 10, "°"))
	_row(box, "引信时长", _spin(box, "kp_fuse", 0.1, 5, 0.1, "s"))
	_row(box, "爆炸半径", _spin(box, "kp_radius", 50, 900, 10, "px"))
	_row(box, "爆炸伤害", _spin(box, "kp_edmg", 1, 150, 1))
	_row(box, "移速惩罚×", _spin(box, "move_penalty", 0.3, 1.0, 0.05))
	_row(box, "跳跃惩罚×", _spin(box, "jump_penalty", 0.3, 1.0, 0.05))
	box.add_child(DevUIKit.label("其他描述(玩法定位 / 特殊行为预期)", 20, Color(0.75, 0.8, 0.85)))
	box.add_child(_text(box, "description", "例:贴身缠斗用,挥空有硬直;可反弹飞行道具…", 96))


func _apply_kind_visibility() -> void:
	var kind: String = CardSchema.WEAPON_KINDS[(_f_wp["kind"] as OptionButton).selected]
	var melee: bool = kind == "melee"
	(_row_wp["mag_size"] as Control).visible = not melee
	(_row_wp["reload_time"] as Control).visible = not melee
	for k in ["bullet_speed", "bullet_range", "pellet_count", "spread_deg", "bullet_gravity", "full_auto", "heavy_aim"]:
		(_row_wp[k] as Control).visible = not melee
	(_row_wp["kp_range"] as Control).visible = melee
	(_row_wp["kp_arc"] as Control).visible = melee
	var thrown: bool = kind == "thrown"
	for k in ["kp_fuse", "kp_radius", "kp_edmg"]:
		(_row_wp[k] as Control).visible = thrown


func _fill_weapon() -> void:
	_f_wp["name"].text = str(_card.get("name", ""))
	_f_wp["kind"].selected = maxi(0, CardSchema.WEAPON_KINDS.find(str(_card.get("kind", "gun"))))
	_f_wp["appearance"].text = str(_card.get("appearance", ""))
	_f_wp["attack_interval"].value = float(_card.get("attack_interval", 0.5))
	_f_wp["mag_size"].value = float(_card.get("mag_size", 12))
	_f_wp["reload_time"].value = float(_card.get("reload_time", 1.2))
	_f_wp["damage"].value = float(_card.get("damage", 10))
	_f_wp["impact"].value = float(_card.get("impact", 60))
	_f_wp["tier"].selected = maxi(0, CardSchema.WEAPON_TIERS.find(str(_card.get("tier", "light"))))
	_f_wp["full_auto"].button_pressed = bool(_card.get("full_auto", false))
	_f_wp["heavy_aim"].button_pressed = bool(_card.get("heavy_aim", false))
	_f_wp["slot"].value = float(_card.get("slot", 6))
	_f_wp["bullet_speed"].value = float(_card.get("bullet_speed", 900))
	_f_wp["bullet_range"].value = float(_card.get("bullet_range", 600))
	_f_wp["pellet_count"].value = float(_card.get("pellet_count", 1))
	_f_wp["spread_deg"].value = float(_card.get("spread_deg", 0))
	_f_wp["bullet_gravity"].value = float(_card.get("bullet_gravity", 0))
	_f_wp["move_penalty"].value = float(_card.get("move_penalty", 1.0))
	_f_wp["jump_penalty"].value = float(_card.get("jump_penalty", 1.0))
	_f_wp["description"].text = str(_card.get("description", ""))
	var kp: Dictionary = _card.get("kind_params", {})
	_f_wp["kp_range"].value = float(kp.get("range", 80.0))
	_f_wp["kp_arc"].value = float(kp.get("arc_deg", 120.0))
	_f_wp["kp_fuse"].value = float(kp.get("fuse_time", 0.8))
	_f_wp["kp_radius"].value = float(kp.get("explosion_radius", 300.0))
	_f_wp["kp_edmg"].value = float(kp.get("explosion_damage", 30))
	_apply_kind_visibility()


# ── 收集 + 防抖保存 ──

func _on_changed(_v = null) -> void:
	if _loading:
		return
	_save_seq += 1
	var seq := _save_seq
	get_tree().create_timer(DEBOUNCE).timeout.connect(func() -> void:
		if seq == _save_seq:
			_save_now())


func _save_now() -> void:
	if _op_box.visible:
		_collect_operator()
	elif _prop_box.visible:
		_collect_prop()
	else:
		_collect_weapon()
	var errs := CardStore.save_card(_card)
	if errs.is_empty():
		card_saved.emit(_card)
	else:
		save_failed.emit(errs)


func _collect_operator() -> void:
	_card["name"] = (_f_op["name"] as LineEdit).text
	_card["max_hp"] = int((_f_op["max_hp"] as SpinBox).value)
	_card["appearance"] = (_f_op["appearance"] as TextEdit).text
	_card["story"] = (_f_op["story"] as TextEdit).text
	_card["texture_mode"] = CardSchema.TEXTURE_MODES[(_f_op["texture_mode"] as OptionButton).selected]
	_card["tint"] = (_f_op["tint"] as LineEdit).text.strip_edges()
	var skills: Array = []
	for row in _skill_rows:
		skills.append({
			"name": (row["name"] as LineEdit).text,
			"key": CardSchema.SKILL_KEYS[(row["key"] as OptionButton).selected],
			"cooldown": (row["cooldown"] as SpinBox).value,
			"desc": (row["desc"] as TextEdit).text,
		})
	_card["skills"] = skills
	(_card["stats"] as Dictionary)["move_speed_mult"] = (_f_op["move_speed_mult"] as SpinBox).value
	(_card["stats"] as Dictionary)["jump_mult"] = (_f_op["jump_mult"] as SpinBox).value
	(_card["stats"] as Dictionary)["armor"] = int((_f_op["armor"] as SpinBox).value)


func _collect_weapon() -> void:
	_card["name"] = (_f_wp["name"] as LineEdit).text
	_card["kind"] = CardSchema.WEAPON_KINDS[(_f_wp["kind"] as OptionButton).selected]
	_card["appearance"] = (_f_wp["appearance"] as TextEdit).text
	_card["attack_interval"] = (_f_wp["attack_interval"] as SpinBox).value
	_card["mag_size"] = int((_f_wp["mag_size"] as SpinBox).value)
	_card["reload_time"] = (_f_wp["reload_time"] as SpinBox).value
	_card["damage"] = int((_f_wp["damage"] as SpinBox).value)
	_card["impact"] = (_f_wp["impact"] as SpinBox).value
	_card["tier"] = CardSchema.WEAPON_TIERS[(_f_wp["tier"] as OptionButton).selected]
	_card["full_auto"] = (_f_wp["full_auto"] as CheckButton).button_pressed
	_card["heavy_aim"] = (_f_wp["heavy_aim"] as CheckButton).button_pressed
	_card["slot"] = int((_f_wp["slot"] as SpinBox).value)
	_card["bullet_speed"] = (_f_wp["bullet_speed"] as SpinBox).value
	_card["bullet_range"] = (_f_wp["bullet_range"] as SpinBox).value
	_card["pellet_count"] = int((_f_wp["pellet_count"] as SpinBox).value)
	_card["spread_deg"] = (_f_wp["spread_deg"] as SpinBox).value
	_card["bullet_gravity"] = (_f_wp["bullet_gravity"] as SpinBox).value
	_card["move_penalty"] = (_f_wp["move_penalty"] as SpinBox).value
	_card["jump_penalty"] = (_f_wp["jump_penalty"] as SpinBox).value
	_card["description"] = (_f_wp["description"] as TextEdit).text
	var kind := str(_card["kind"])
	var kp := CardSchema.kind_params_defaults(kind)
	match kind:
		"melee":
			kp["range"] = (_f_wp["kp_range"] as SpinBox).value
			kp["arc_deg"] = (_f_wp["kp_arc"] as SpinBox).value
		"thrown":
			kp["fuse_time"] = (_f_wp["kp_fuse"] as SpinBox).value
			kp["explosion_radius"] = (_f_wp["kp_radius"] as SpinBox).value
			kp["explosion_damage"] = int((_f_wp["kp_edmg"] as SpinBox).value)
	_card["kind_params"] = kp


# ── 道具表单 ──
func _build_prop(box: VBoxContainer) -> void:
	box.add_child(DevUIKit.label("道具卡", 26, Color(0.55, 0.95, 1.0)))
	_row(box, "名称", _line(box, "name", "道具名称"))
	var kind := _opt(box, "kind", PROP_KIND_LABELS)
	_row(box, "性质", kind)
	kind.item_selected.connect(func(_i: int) -> void: _apply_prop_kind_visibility())
	box.add_child(DevUIKit.label("外貌描述(投掷物/烟雾像素画按此生成,或用「导入手绘素材」)", 20, Color(0.75, 0.8, 0.85)))
	box.add_child(_text(box, "appearance", "例:橙红色圆柱罐体,顶部按压引信,罐体白圈标识…", 96))
	_row(box, "投掷间隔", _spin(box, "attack_interval", 0.1, 10.0, 0.1, "s"))
	_row(box, "每次复活携带", _spin(box, "mag_size", 1, 9, 1, "枚(不可换弹)"))
	_row(box, "注册槽位", _spin(box, "slot", 0, 10, 1, "(8=击退 9=吸引 10=烟雾;0=设计稿)"))
	_row(box, "分级", _opt(box, "tier", TIER_LABELS))
	box.add_child(DevUIKit.label("弹道(投掷抛物线)", 20, Color(0.75, 0.8, 0.85)))
	_row(box, "投掷初速", _spin(box, "bullet_speed", 100, 3000, 50, "px/s"))
	_row(box, "最大飞行", _spin(box, "bullet_range", 100, 3000, 50, "px"))
	_row(box, "弹体重力×", _spin(box, "bullet_gravity", 0, 1, 0.05))
	box.add_child(DevUIKit.label("效果参数", 20, Color(0.75, 0.8, 0.85)))
	_row(box, "起效延迟", _spin(box, "kp_fuse", 0.0, 5, 0.1, "s(首次碰撞后)"))
	_row(box, "作用半径", _spin(box, "kp_radius", 50, 900, 10, "px"))
	_row(box, "推/吸强度", _spin(box, "kp_force", 0, 9000, 50, "(负=吸引)"))
	_row(box, "烟雾时长", _spin(box, "kp_smoke", 0, 30, 0.5, "s"))
	_row(box, "移速惩罚×", _spin(box, "move_penalty", 0.3, 1.0, 0.05))
	_row(box, "跳跃惩罚×", _spin(box, "jump_penalty", 0.3, 1.0, 0.05))
	box.add_child(DevUIKit.label("其他描述(效果预期/使用场景)", 20, Color(0.75, 0.8, 0.85)))
	box.add_child(_text(box, "description", "例:击退范围内所有实体(含子弹/自己),不造成伤害…", 96))
	_apply_prop_kind_visibility()


func _apply_prop_kind_visibility() -> void:
	var kind: String = CardSchema.PROP_KINDS[(_f_prop["kind"] as OptionButton).selected]
	var smoke: bool = kind == "smoke"
	(_row_prop["kp_force"] as Control).visible = not smoke
	(_row_prop["kp_smoke"] as Control).visible = smoke


func _fill_prop() -> void:
	_f_prop["name"].text = str(_card.get("name", ""))
	_f_prop["kind"].selected = maxi(0, CardSchema.PROP_KINDS.find(str(_card.get("kind", "knockback"))))
	_f_prop["appearance"].text = str(_card.get("appearance", ""))
	_f_prop["attack_interval"].value = float(_card.get("attack_interval", 0.8))
	_f_prop["mag_size"].value = float(_card.get("mag_size", 2))
	_f_prop["slot"].value = float(_card.get("slot", 8))
	_f_prop["tier"].selected = maxi(0, CardSchema.WEAPON_TIERS.find(str(_card.get("tier", "light"))))
	_f_prop["bullet_speed"].value = float(_card.get("bullet_speed", 900))
	_f_prop["bullet_range"].value = float(_card.get("bullet_range", 1200))
	_f_prop["bullet_gravity"].value = float(_card.get("bullet_gravity", 0.45))
	_f_prop["move_penalty"].value = float(_card.get("move_penalty", 1.0))
	_f_prop["jump_penalty"].value = float(_card.get("jump_penalty", 1.0))
	_f_prop["description"].text = str(_card.get("description", ""))
	var kp: Dictionary = _card.get("kind_params", {})
	_f_prop["kp_fuse"].value = float(kp.get("fuse_time", 0.5))
	_f_prop["kp_radius"].value = float(kp.get("blast_radius", 260.0))
	_f_prop["kp_force"].value = float(kp.get("blast_force", 2600.0))
	_f_prop["kp_smoke"].value = float(kp.get("smoke_duration", 6.0))
	_apply_prop_kind_visibility()


func _collect_prop() -> void:
	_card["name"] = (_f_prop["name"] as LineEdit).text
	_card["kind"] = CardSchema.PROP_KINDS[(_f_prop["kind"] as OptionButton).selected]
	_card["appearance"] = (_f_prop["appearance"] as TextEdit).text
	_card["attack_interval"] = (_f_prop["attack_interval"] as SpinBox).value
	_card["mag_size"] = int((_f_prop["mag_size"] as SpinBox).value)
	_card["slot"] = int((_f_prop["slot"] as SpinBox).value)
	_card["tier"] = CardSchema.WEAPON_TIERS[(_f_prop["tier"] as OptionButton).selected]
	_card["bullet_speed"] = (_f_prop["bullet_speed"] as SpinBox).value
	_card["bullet_range"] = (_f_prop["bullet_range"] as SpinBox).value
	_card["bullet_gravity"] = (_f_prop["bullet_gravity"] as SpinBox).value
	_card["move_penalty"] = (_f_prop["move_penalty"] as SpinBox).value
	_card["jump_penalty"] = (_f_prop["jump_penalty"] as SpinBox).value
	_card["description"] = (_f_prop["description"] as TextEdit).text
	var kp := {"fuse_time": 0.5, "blast_radius": 260.0, "blast_force": 0.0, "smoke_duration": 0.0}
	kp["fuse_time"] = (_f_prop["kp_fuse"] as SpinBox).value
	kp["blast_radius"] = (_f_prop["kp_radius"] as SpinBox).value
	kp["blast_force"] = (_f_prop["kp_force"] as SpinBox).value
	kp["smoke_duration"] = (_f_prop["kp_smoke"] as SpinBox).value
	var kind := str(_card["kind"])
	if kind == "smoke":
		kp["blast_force"] = 0.0
	elif kind == "attraction":
		kp["blast_force"] = -absf(float(kp["blast_force"]))
	else:
		kp["blast_force"] = absf(float(kp["blast_force"]))
	_card["kind_params"] = kp

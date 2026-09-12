class_name CardSchema
extends RefCounted

# 干员卡/武器卡的数据定义(DevTools):字段默认值 + 补全 + 校验。
# 职责边界:只懂「卡长什么样」;磁盘读写在 card_store.gd,提示词在 prompt_builder.gd。
# 卡是单一事实来源:agent 施工提示词携带卡 JSON 全文,游戏侧实现以卡为准。

const SCHEMA_VERSION := 1
const TYPE_OPERATOR := "operator"
const TYPE_WEAPON := "weapon"
const TYPE_PROP := "prop"
const CARD_TYPES := [TYPE_OPERATOR, TYPE_WEAPON, TYPE_PROP]

# id 即文件名:小写字母开头,小写字母/数字/下划线,2~32 字符
const ID_REGEX := "^[a-z][a-z0-9_]{2,31}$"

const SKILL_KEYS := ["skill_1", "skill_2", "skill_3"]   # 对应 project.godot 待注册动作(默认键 Z/X/C)
const MAX_SKILLS := 3
const WEAPON_KINDS := ["gun", "melee", "thrown", "special"]
const PROP_KINDS := ["knockback", "attraction", "smoke"]   # 击退炮 / 吸力炮 / 烟雾弹
const WEAPON_TIERS := ["light", "medium", "heavy"]
const TEXTURE_MODES := ["tint", "sheet"]


## 新卡默认值(envelope + 按类型的字段集)
static func make_default(type: String, id: String) -> Dictionary:
	var card := {
		"schema_version": SCHEMA_VERSION,
		"card_type": type,
		"id": id,
		"name": "",
		"rev": 1,
		"created_at": Time.get_datetime_string_from_system(),
		"updated_at": Time.get_datetime_string_from_system(),
	}
	if type == TYPE_OPERATOR:
		card["max_hp"] = 80
		card["appearance"] = ""      # 外貌描述:喂给像素画生成器
		card["story"] = ""           # 干员故事
		card["skills"] = []          # [{name, key, cooldown, desc}] ≤3 条
		card["stats"] = {"move_speed_mult": 1.0, "jump_mult": 1.0, "armor": 0}
		card["tint"] = ""            # 色相(度),空=不染色;texture_mode=tint 时的廉价换肤
		card["texture_mode"] = "tint"   # tint=现成染色管线 | sheet=48×48 五姿态图集
		card["portrait"] = {"size": [96, 96]}
	elif type == TYPE_WEAPON:
		card["kind"] = "gun"         # gun 枪械 | melee 冷兵器 | thrown 爆炸投掷 | special 其他
		card["appearance"] = ""
		card["attack_interval"] = 0.5   # → tscn fire_cooldown
		card["mag_size"] = 12        # 0 = 无弹夹(melee 不接换弹)
		card["reload_time"] = 1.2
		card["description"] = ""     # 玩法定位/其他描述
		card["damage"] = 10
		card["impact"] = 60.0
		card["tier"] = "light"
		card["full_auto"] = false
		card["heavy_aim"] = false
		card["bullet_speed"] = 900.0
		card["bullet_range"] = 600.0
		card["bullet_size"] = 1.0
		card["pellet_count"] = 1
		card["spread_deg"] = 0.0
		card["bullet_gravity"] = 0.0
		card["move_penalty"] = 1.0
		card["jump_penalty"] = 1.0
		card["slot"] = 6             # 0=纯设计稿不注册;>5 需扩槽(提示词分派重构模板)
		card["kind_params"] = {}
	elif type == TYPE_PROP:
		card["kind"] = "knockback"     # knockback 击退 | attraction 吸引 | smoke 烟雾
		card["appearance"] = ""        # 道具外貌(agent 生成或手绘导入)
		card["attack_interval"] = 0.8  # 投掷间隔
		card["mag_size"] = 2           # 每次复活携带数(不可换弹)
		card["reload_time"] = 0.0
		card["description"] = ""
		card["damage"] = 0             # 道具不造成直接伤害(占位字段,恒 0)
		card["impact"] = 0.0
		card["tier"] = "light"
		card["full_auto"] = false
		card["heavy_aim"] = false
		card["bullet_speed"] = 900.0   # 投掷物初速
		card["bullet_range"] = 1200.0
		card["bullet_size"] = 1.0
		card["pellet_count"] = 1
		card["spread_deg"] = 0.0
		card["bullet_gravity"] = 0.45  # 抛物线
		card["move_penalty"] = 1.0
		card["jump_penalty"] = 1.0
		card["slot"] = 8               # 8=击退 9=吸引 10=烟雾;0=纯设计稿
		card["kind_params"] = {
			"fuse_time": 0.5,
			"blast_radius": 260.0,
			"blast_force": 2600.0,
			"smoke_duration": 6.0,
		}
	return card


## kind_params 按 kind 的默认值(表单新建该类参数行时用)
static func kind_params_defaults(kind: String) -> Dictionary:
	match kind:
		"melee":
			return {"range": 80.0, "arc_deg": 120.0}
		"thrown":
			return {"fuse_time": 0.8, "explosion_radius": 300.0, "explosion_damage": 30}
	return {}


## 读档后补全缺失的可选字段(手改 JSON/旧版卡兼容):返回补全后的新字典
static func apply_defaults(card: Dictionary) -> Dictionary:
	var type := str(card.get("card_type", ""))
	var full := make_default(type, str(card.get("id", "")))
	for k in full:
		if not card.has(k):
			card[k] = full[k]
	if type == TYPE_OPERATOR:
		var stats: Dictionary = card["stats"]
		for k in (full["stats"] as Dictionary):
			if not stats.has(k):
				stats[k] = full["stats"][k]
	return card


## 校验:返回错误列表,空 = 通过(id 唯一性 = 文件名即 id,天然成立,不在此次检查)
static func validate(card: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var type := str(card.get("card_type", ""))
	if type != TYPE_OPERATOR and type != TYPE_WEAPON and type != TYPE_PROP:
		errs.append("card_type 非法:%s" % type)
		return errs
	var id := str(card.get("id", ""))
	if RegEx.create_from_string(ID_REGEX).search(id) == null:
		errs.append("id 非法(需 %s):%s" % [ID_REGEX, id])
	if str(card.get("name", "")).strip_edges().is_empty():
		errs.append("名称不能为空")
	match type:
		TYPE_OPERATOR:
			_validate_operator(card, errs)
		TYPE_WEAPON:
			_validate_weapon(card, errs)
		TYPE_PROP:
			_validate_prop(card, errs)
	return errs


static func _validate_operator(card: Dictionary, errs: Array[String]) -> void:
	if int(card.get("max_hp", 0)) < 1 or int(card.get("max_hp", 0)) > 999:
		errs.append("血量需在 1~999:%s" % str(card.get("max_hp")))
	var skills: Array = card.get("skills", [])
	if skills.size() > MAX_SKILLS:
		errs.append("技能最多 %d 条(当前 %d)" % [MAX_SKILLS, skills.size()])
	var keys_seen: Array = []
	for i in skills.size():
		var s: Dictionary = skills[i] if typeof(skills[i]) == TYPE_DICTIONARY else {}
		if str(s.get("name", "")).strip_edges().is_empty():
			errs.append("技能 %d 缺名称" % (i + 1))
		if str(s.get("desc", "")).strip_edges().is_empty():
			errs.append("技能「%s」缺描述" % s.get("name", i + 1))
		var key := str(s.get("key", ""))
		if not key in SKILL_KEYS:
			errs.append("技能「%s」key 非法(需 %s):%s" % [s.get("name", i + 1), "+".join(SKILL_KEYS), key])
		elif key in keys_seen:
			errs.append("技能 key 重复:%s" % key)
		else:
			keys_seen.append(key)
		if float(s.get("cooldown", 0.0)) < 0.0:
			errs.append("技能「%s」冷却不能为负" % s.get("name", i + 1))
	if str(card.get("texture_mode", "")) not in TEXTURE_MODES:
		errs.append("texture_mode 非法(需 tint|sheet):%s" % str(card.get("texture_mode")))
	var tint := str(card.get("tint", ""))
	if not tint.is_empty() and (not tint.is_valid_float() or float(tint) < 0.0 or float(tint) >= 360.0):
		errs.append("tint 需为 0~360 的色相角度或留空:%s" % tint)


static func _validate_weapon(card: Dictionary, errs: Array[String]) -> void:
	if str(card.get("kind", "")) not in WEAPON_KINDS:
		errs.append("武器性质非法(需 %s):%s" % ["|".join(WEAPON_KINDS), str(card.get("kind"))])
	if float(card.get("attack_interval", 0.0)) <= 0.0:
		errs.append("攻击间隔需 > 0:%s" % str(card.get("attack_interval")))
	if int(card.get("mag_size", -1)) < 0:
		errs.append("弹夹容量需 ≥ 0(0=无弹夹):%s" % str(card.get("mag_size")))
	if int(card.get("damage", 0)) < 1:
		errs.append("伤害需 ≥ 1:%s" % str(card.get("damage")))
	if int(card.get("slot", -1)) < 0 or int(card.get("slot", 0)) > 9:
		errs.append("槽位需在 0~9(0=不注册):%s" % str(card.get("slot")))
	if str(card.get("tier", "")) not in WEAPON_TIERS:
		errs.append("tier 非法(需 %s):%s" % ["|".join(WEAPON_TIERS), str(card.get("tier"))])
	if int(card.get("pellet_count", 1)) < 1:
		errs.append("弹丸数需 ≥ 1:%s" % str(card.get("pellet_count")))


static func _validate_prop(card: Dictionary, errs: Array[String]) -> void:
	if str(card.get("kind", "")) not in PROP_KINDS:
		errs.append("道具性质非法(需 %s):%s" % ["|".join(PROP_KINDS), str(card.get("kind"))])
	if float(card.get("attack_interval", 0.0)) <= 0.0:
		errs.append("投掷间隔需 > 0:%s" % str(card.get("attack_interval")))
	var mag := int(card.get("mag_size", 0))
	if mag < 1 or mag > 9:
		errs.append("每次复活携带数需在 1~9:%s" % str(mag))
	var slot := int(card.get("slot", -1))
	if slot != 0 and slot not in [8, 9, 10]:
		errs.append("道具槽位需为 0(设计稿)或 8/9/10:%s" % str(slot))
	if str(card.get("tier", "")) not in WEAPON_TIERS:
		errs.append("tier 非法(需 %s):%s" % ["|".join(WEAPON_TIERS), str(card.get("tier"))])
	var kp: Dictionary = card.get("kind_params", {})
	var radius := float(kp.get("blast_radius", 0.0))
	if radius < 50.0 or radius > 900.0:
		errs.append("作用半径需在 50~900:%s" % str(radius))
	var kind := str(card.get("kind", ""))
	if kind == "smoke":
		if float(kp.get("smoke_duration", 0.0)) <= 0.0:
			errs.append("烟雾时长需 > 0")
	elif float(kp.get("blast_force", 0.0)) == 0.0:
		errs.append("推/吸强度不能为 0")

class_name EditorSchema
extends RefCounted

# 素材编辑器数据层(DevTools/editor 重写版):卡类型/字段/校验/美术槽/示范模板。
# 设计原则(画师优先):所有美术资产最终由人工产出,AI 生成仅作占位 —— 每张卡带一组
# 「美术槽」,每个槽映射一个明确的落盘文件,编辑器提供 上传/导出占位/删除,游戏侧
# 优先读人工素材、缺省回退 AI 占位。卡 JSON 格式与旧版完全兼容(cards/ 目录不动)。

const SCHEMA_VERSION := 1
const TYPE_OPERATOR := "operator"
const TYPE_WEAPON := "weapon"
const TYPE_PROP := "prop"
const CARD_TYPES := [TYPE_WEAPON, TYPE_OPERATOR, TYPE_PROP]
const TYPE_LABELS := {TYPE_WEAPON: "武器", TYPE_OPERATOR: "角色", TYPE_PROP: "道具"}

const ID_REGEX := "^[a-z][a-z0-9_]{2,31}$"
const SKILL_KEYS := ["skill_1", "skill_2", "skill_3"]
const MAX_SKILLS := 3
const WEAPON_KINDS := ["gun", "melee", "thrown", "special"]
const PROP_KINDS := ["knockback", "attraction", "smoke"]
const WEAPON_TIERS := ["light", "medium", "heavy"]
const TEXTURE_MODES := ["tint", "sheet"]

# 现役槽位 ↔ 卡 id(美术槽与游戏资源对接的桥;新增现役武器在此登记)
const SLOT_CARD_IDS := {
	1: "wp_pistol", 2: "wp_rifle", 3: "wp_m82a1", 4: "wp_s686",
	5: "wp_grenade_launcher", 6: "wp_laser_gun",
}


# ── 美术槽定义:每槽一个落盘文件;human=人工上传,AI 占位只是兜底 ──
## 返回 [{key, label, file, desc, game}] ;file 相对 DevTools/cards/;game=游戏侧消费点说明
static func art_slots(type: String, id: String) -> Array:
	var dir := folder_of(type)
	match type:
		TYPE_WEAPON:
			return [
				{"key": "card", "label": "卡面图", "file": "%s/%s.png" % [dir, id],
					"desc": "编辑器/选人展示", "game": "编辑器 + 主菜单展示"},
				{"key": "silhouette", "label": "HUD 白剪影", "file": "%s/%s__silhouette.png" % [dir, id],
					"desc": "单色剪影,透明背景;建议 96x48", "game": "HUD 左下 + 武器选择栏(优先于图集)"},
				{"key": "gun", "label": "枪身贴图", "file": "%s/%s__gun.png" % [dir, id],
					"desc": "对局内武器精灵,原始像素尺寸", "game": "对局内武器 Sprite(优先于图集)"},
				{"key": "bullet", "label": "弹丸贴图", "file": "%s/%s__bullet.png" % [dir, id],
					"desc": "子弹/投掷物贴图,可省略", "game": "对局内弹丸 Sprite(优先于图集)"},
			]
		TYPE_OPERATOR:
			return [
				{"key": "card", "label": "头像", "file": "%s/%s.png" % [dir, id],
					"desc": "96x96 像素头像", "game": "编辑器 + 主菜单选人"},
				{"key": "body", "label": "角色精灵(设计稿)", "file": "%s/%s__body.png" % [dir, id],
					"desc": "48x48 单帧或五姿态图集;当前对局内仍走 tint 管线,此图供施工参考",
					"game": "施工参考(接入对局内精灵为后续施工项)"},
			]
		TYPE_PROP:
			return [
				{"key": "card", "label": "卡面图", "file": "%s/%s.png" % [dir, id],
					"desc": "编辑器展示", "game": "编辑器展示"},
				{"key": "world", "label": "对局内贴图(设计稿)", "file": "%s/%s__world.png" % [dir, id],
					"desc": "投掷物/落地震体像素图;当前道具实体为程序化绘制,此图供施工参考",
					"game": "施工参考(接入实体贴图为后续施工项)"},
			]
	return []


## 槽位落盘绝对路径(res:// 域)
static func art_path(type: String, id: String, slot_key: String) -> String:
	for s in art_slots(type, id):
		if str(s["key"]) == slot_key:
			return "res://DevTools/cards/" + str(s["file"])
	return ""


# ── 卡默认值(与旧版 schema 兼容;新增字段向尾部追加) ──
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
		card["appearance"] = ""
		card["story"] = ""
		card["skills"] = []
		card["stats"] = {"move_speed_mult": 1.0, "jump_mult": 1.0, "armor": 0}
		card["tint"] = ""
		card["texture_mode"] = "tint"
		card["portrait"] = {"size": [96, 96]}
	elif type == TYPE_WEAPON:
		card["kind"] = "gun"
		card["appearance"] = ""
		card["attack_interval"] = 0.5
		card["mag_size"] = 12
		card["reload_time"] = 1.2
		card["description"] = ""
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
		card["slot"] = 6
		card["kind_params"] = {}
	elif type == TYPE_PROP:
		card["kind"] = "knockback"
		card["appearance"] = ""
		card["attack_interval"] = 0.8
		card["mag_size"] = 2
		card["reload_time"] = 0.0
		card["description"] = ""
		card["damage"] = 0
		card["impact"] = 0.0
		card["tier"] = "light"
		card["full_auto"] = false
		card["heavy_aim"] = false
		card["bullet_speed"] = 900.0
		card["bullet_range"] = 1200.0
		card["bullet_size"] = 1.0
		card["pellet_count"] = 1
		card["spread_deg"] = 0.0
		card["bullet_gravity"] = 0.45
		card["move_penalty"] = 1.0
		card["jump_penalty"] = 1.0
		card["slot"] = 8
		card["kind_params"] = {
			"fuse_time": 0.5, "blast_radius": 260.0, "blast_force": 2600.0, "smoke_duration": 6.0,
		}
	card["notes"] = ""   # 特殊要求(备注):逐字进施工提示词,画师/策划的特殊约定写这里
	card["mod_history"] = []   # 修改历史:[{rev,time,req}] 每轮增量修改发送时由编辑器追加
	return card


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


# ── 示范模板:每类型一张填好的卡(新建时可选「从示范模板开始」) ──
static func sample_template(type: String) -> Dictionary:
	var card := make_default(type, "")
	match type:
		TYPE_WEAPON:
			card["id"] = "wp_sample_rifle"
			card["name"] = "示范突击步枪"
			card["kind"] = "gun"
			card["tier"] = "medium"
			card["slot"] = 0   # 示范默认设计稿,正式注册改现役槽或扩槽
			card["attack_interval"] = 0.12
			card["mag_size"] = 30
			card["reload_time"] = 1.8
			card["damage"] = 8
			card["impact"] = 40.0
			card["bullet_speed"] = 1400.0
			card["bullet_range"] = 1400.0
			card["full_auto"] = true
			card["appearance"] = "紧凑无托步枪,青灰机匣配荧光准星,枪管短粗,像素风 3/4 视角"
			card["description"] = "中距压制:射速快单发低,弹道稳定,换弹偏慢逼迫节奏管理。"
			card["notes"] = "示范模板备注:换弹动画希望有明显的枪机后拉;弹壳抛向右侧。"
		TYPE_OPERATOR:
			card["id"] = "op_sample_vanguard"
			card["name"] = "示范先锋"
			card["max_hp"] = 100
			card["tint"] = "135"
			card["texture_mode"] = "tint"
			card["appearance"] = "敦实突击手,青色作战服+橙色目镜,肩挂弹药盒,像素风 3/4 视角"
			card["story"] = "第一批进入遗迹的勘测员,信奉火力开路。"
			card["skills"] = [
				{"name": "战术冲刺", "key": "skill_1", "cooldown": 6.0, "desc": "向朝向瞬时冲刺一小段,期间免疫击退。"},
				{"name": "掩体姿态", "key": "skill_2", "cooldown": 12.0, "desc": "正面受伤减半、移速减半,持续 4 秒。"},
				{"name": "空投补给", "key": "skill_3", "cooldown": 30.0, "desc": "呼叫补给箱:拾取回 30 血并补满弹夹。"},
			]
			card["notes"] = "示范模板备注:技能释放要有 0.2s 白闪反馈;倒地语音不做。"
		TYPE_PROP:
			card["id"] = "pr_sample_smoke"
			card["name"] = "示范烟雾弹"
			card["kind"] = "smoke"
			card["slot"] = 10
			card["mag_size"] = 2
			card["attack_interval"] = 0.8
			card["bullet_gravity"] = 0.45
			card["kind_params"] = {"fuse_time": 0.5, "blast_radius": 260.0, "blast_force": 0.0, "smoke_duration": 6.0}
			card["appearance"] = "灰绿圆柱罐体,顶部拉环,弹体带竖向防滑纹,像素风"
			card["description"] = "落点生成烟雾:遮挡双方视线(子弹/鸟索敌),持续 6 秒。"
			card["notes"] = "示范模板备注:烟雾用 3 层视差圆,边缘颗粒感。"
	return card


# ── 表单字段规格(通用渲染驱动) ──
## kind: text/int/float/bool/choice;choices 选项;hint 提示
static func fields_for(type: String) -> Array:
	match type:
		TYPE_WEAPON:
			return [
				{"key": "name", "label": "名称", "kind": "text"},
				{"key": "kind", "label": "性质", "kind": "choice", "choices": WEAPON_KINDS},
				{"key": "tier", "label": "定位", "kind": "choice", "choices": WEAPON_TIERS},
				{"key": "slot", "label": "槽位(0=设计稿,现役1~6,扩槽7+)", "kind": "int"},
				{"key": "damage", "label": "伤害", "kind": "int"},
				{"key": "attack_interval", "label": "攻击间隔(秒)", "kind": "float"},
				{"key": "mag_size", "label": "弹夹(0=无)", "kind": "int"},
				{"key": "reload_time", "label": "换弹(秒)", "kind": "float"},
				{"key": "impact", "label": "击退", "kind": "float"},
				{"key": "bullet_speed", "label": "弹速", "kind": "float"},
				{"key": "bullet_range", "label": "射程", "kind": "float"},
				{"key": "bullet_size", "label": "弹径倍率", "kind": "float"},
				{"key": "pellet_count", "label": "弹丸数", "kind": "int"},
				{"key": "spread_deg", "label": "散布(度)", "kind": "float"},
				{"key": "bullet_gravity", "label": "弹道重力倍率", "kind": "float"},
				{"key": "move_penalty", "label": "持枪移速倍率", "kind": "float"},
				{"key": "jump_penalty", "label": "持枪跳跃倍率", "kind": "float"},
				{"key": "full_auto", "label": "全自动", "kind": "bool"},
				{"key": "heavy_aim", "label": "重武器预瞄", "kind": "bool"},
				{"key": "appearance", "label": "外貌描述(喂给占位画)", "kind": "text"},
				{"key": "description", "label": "玩法描述", "kind": "text"},
			]
		TYPE_OPERATOR:
			return [
				{"key": "name", "label": "名称", "kind": "text"},
				{"key": "max_hp", "label": "血量", "kind": "int"},
				{"key": "tint", "label": "色相(0~360,空=不染)", "kind": "text"},
				{"key": "texture_mode", "label": "皮肤模式(tint|sheet)", "kind": "choice", "choices": TEXTURE_MODES},
				{"key": "appearance", "label": "外貌描述", "kind": "text"},
				{"key": "story", "label": "背景故事", "kind": "text"},
			]
		TYPE_PROP:
			return [
				{"key": "name", "label": "名称", "kind": "text"},
				{"key": "kind", "label": "性质", "kind": "choice", "choices": PROP_KINDS},
				{"key": "slot", "label": "槽位(0=设计稿,8/9/10=击退/吸引/烟雾)", "kind": "int"},
				{"key": "attack_interval", "label": "投掷间隔(秒)", "kind": "float"},
				{"key": "mag_size", "label": "每次复活携带数", "kind": "int"},
				{"key": "bullet_speed", "label": "投掷初速", "kind": "float"},
				{"key": "bullet_range", "label": "射程", "kind": "float"},
				{"key": "bullet_gravity", "label": "弹道重力倍率", "kind": "float"},
				{"key": "appearance", "label": "外貌描述", "kind": "text"},
				{"key": "description", "label": "效果描述", "kind": "text"},
			]
	return []


static func folder_of(type: String) -> String:
	return str(type) + "s"   # weapon→weapons / operator→operators / prop→props


# ── 校验(自旧版 schema 移植) ──
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
			errs.append("技能「%s」key 非法:%s" % [s.get("name", i + 1), key])
		elif key in keys_seen:
			errs.append("技能 key 重复:%s" % key)
		else:
			keys_seen.append(key)
		if float(s.get("cooldown", 0.0)) < 0.0:
			errs.append("技能「%s」冷却不能为负" % s.get("name", i + 1))
	if str(card.get("texture_mode", "")) not in TEXTURE_MODES:
		errs.append("texture_mode 非法(tint|sheet):%s" % str(card.get("texture_mode")))
	var tint := str(card.get("tint", ""))
	if not tint.is_empty() and (not tint.is_valid_float() or float(tint) < 0.0 or float(tint) >= 360.0):
		errs.append("tint 需为 0~360 色相角度或留空:%s" % tint)


static func _validate_weapon(card: Dictionary, errs: Array[String]) -> void:
	if str(card.get("kind", "")) not in WEAPON_KINDS:
		errs.append("武器性质非法:%s" % str(card.get("kind")))
	if float(card.get("attack_interval", 0.0)) <= 0.0:
		errs.append("攻击间隔需 > 0")
	if int(card.get("mag_size", -1)) < 0:
		errs.append("弹夹容量需 ≥ 0")
	if int(card.get("damage", 0)) < 1:
		errs.append("伤害需 ≥ 1")
	if int(card.get("slot", -1)) < 0 or int(card.get("slot", 0)) > 9:
		errs.append("槽位需在 0~9")
	if str(card.get("tier", "")) not in WEAPON_TIERS:
		errs.append("tier 非法")
	if int(card.get("pellet_count", 1)) < 1:
		errs.append("弹丸数需 ≥ 1")


static func _validate_prop(card: Dictionary, errs: Array[String]) -> void:
	if str(card.get("kind", "")) not in PROP_KINDS:
		errs.append("道具性质非法:%s" % str(card.get("kind")))
	if float(card.get("attack_interval", 0.0)) <= 0.0:
		errs.append("投掷间隔需 > 0")
	var mag := int(card.get("mag_size", 0))
	if mag < 1 or mag > 9:
		errs.append("每次复活携带数需在 1~9")
	var slot := int(card.get("slot", -1))
	if slot != 0 and slot not in [8, 9, 10]:
		errs.append("道具槽位需为 0(设计稿)或 8/9/10")
	if str(card.get("tier", "")) not in WEAPON_TIERS:
		errs.append("tier 非法")
	var kp: Dictionary = card.get("kind_params", {})
	var radius := float(kp.get("blast_radius", 0.0))
	if radius < 50.0 or radius > 900.0:
		errs.append("作用半径需在 50~900")
	if str(card.get("kind")) == "smoke":
		if float(kp.get("smoke_duration", 0.0)) <= 0.0:
			errs.append("烟雾时长需 > 0")
	elif float(kp.get("blast_force", 0.0)) == 0.0:
		errs.append("推/吸强度不能为 0")

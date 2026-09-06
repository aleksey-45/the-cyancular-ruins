class_name OperatorComponent
extends Node

# 干员组件(实验性,test-ai 分支):与 Climb/Combat/Swim 并列挂在 Player.tscn。
# apply_operator(card) 把卡数据覆盖到实例字段(combat.max_hp/hp、player.move_speed/
# jump_velocity/armor、外貌 tint),零架构改动,不改 PlayerParams 常量。
# 技能子节点由本组件按卡数据动态挂载(SkillBase 子类),由 player.gd 根循环驱动。

const DASH_SPEED := 1200.0
const DASH_TIME := 0.16

var applied_id := ""
var applied_name := ""
var dash_left := 0.0      # >0 = 冲刺中(player.gd 根循环读它接管水平速度)
var dash_dir := 1.0
var shield_left := 0.0    # >0 = 掩体姿态(正面伤害减半 + 移速减半,player.gd 读)
var _skills: Array = []   # [SkillBase]


func apply_operator(card: Dictionary) -> void:
	var id := str(card.get("id", ""))
	if id == applied_id:
		return
	applied_id = id
	applied_name = str(card.get("name", ""))
	var player := get_parent() as Node2D
	var combat: Node = player.get("combat")
	if combat == null:
		push_error("OperatorComponent: 找不到 combat 组件")
		return
	var max_hp := int(card.get("max_hp", 0))
	if max_hp > 0:
		combat.max_hp = max_hp
		combat.hp = max_hp
	var stats: Dictionary = card.get("stats", {})
	player.move_speed = PlayerParams.move_speed * float(stats.get("move_speed_mult", 1.0))
	player.jump_velocity = PlayerParams.jump_velocity * float(stats.get("jump_mult", 1.0))
	player.armor = int(stats.get("armor", 0))
	player.operator_name = applied_name
	_apply_skills(card)
	_apply_appearance(card)
	player.hp_changed.emit(combat.hp, combat.max_hp)


# 按卡 skills 数组动态挂技能节点:脚本按 <卡id>_skill_<n>.gd 约定加载,缺失跳过
func _apply_skills(card: Dictionary) -> void:
	for s in _skills:
		if is_instance_valid(s):
			s.queue_free()
	_skills.clear()
	var id := str(card.get("id", ""))
	var n := 0
	for cfg in card.get("skills", []):
		if typeof(cfg) != TYPE_DICTIONARY:
			continue
		n += 1
		var script_path := "res://Scenes/Player/Skills/%s_skill_%d.gd" % [id, n]
		if not ResourceLoader.exists(script_path):
			push_warning("OperatorComponent: 缺技能脚本 " + script_path)
			continue
		var skill: Node = (load(script_path) as Script).new()
		skill.setup(get_parent() as CharacterBody2D, cfg)
		add_child(skill)
		_skills.append(skill)


# 外貌:tint 模式复用 player_p2_hue.gdshader 挂 AnimatedSprite2D(tint 空 = 不染)
func _apply_appearance(card: Dictionary) -> void:
	var player := get_parent() as Node2D
	var spr: Node = player.get_node_or_null("AnimatedSprite2D")
	if spr == null or not (spr is CanvasItem):
		return
	var tint := str(card.get("tint", ""))
	if str(card.get("texture_mode", "tint")) == "tint" and tint != "" and tint.is_valid_float():
		var mat := ShaderMaterial.new()
		mat.shader = load("res://Scenes/Player/player_p2_hue.gdshader")
		mat.set_shader_parameter("hue_shift", float(tint))
		(spr as CanvasItem).material = mat


# ── 由 player.gd 根循环驱动(组件与技能都不写自己的 _physics_process)──
func update_skills(delta: float, input_source: InputSource) -> void:
	for s in _skills:
		if is_instance_valid(s):
			s.update(delta, input_source)


# 冲刺接管水平速度(根循环在普通过程中检查);冲刺期间免疫击退
func dash_takeover() -> bool:
	if dash_left > 0.0:
		return true
	return false


# 掩体姿态:移速减半系数
func shield_speed_mult() -> float:
	return 0.5 if shield_left > 0.0 else 1.0

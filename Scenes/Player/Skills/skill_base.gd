class_name SkillBase
extends Node

# 技能骨架(实验性):每技能一个子节点,持 {key, cooldown}。
# 不写自己的 _physics_process——由 player.gd 根循环经 OperatorComponent.update_skills 驱动。
# 释放判定走 input_source.is_action_just_pressed(key)(InputSource 泛型动作查询,零改动)。

var key := "skill_1"
var cooldown := 10.0
var player: CharacterBody2D = null
var input_source: InputSource = null
var cd_left := 0.0


func setup(p: CharacterBody2D, cfg: Dictionary) -> void:
	player = p
	key = str(cfg.get("key", key))
	cooldown = float(cfg.get("cooldown", cooldown))
	name = str(cfg.get("name", "Skill"))


# 根循环每帧调用:冷却走表 + 释放判定;子类实现 _activate()(返回 true = 成功,进冷却)
func update(delta: float, src: InputSource) -> void:
	input_source = src
	if cd_left > 0.0:
		cd_left -= delta
		return
	if src == null or not src.is_action_just_pressed(key):
		return
	if _activate():
		cd_left = cooldown


# 子类覆盖:技能每物理帧的持续效果(冲刺位移/护盾计时等);默认空
func physics_tick(_delta: float) -> void:
	pass


# 子类覆盖:激活逻辑;返回 false = 条件不满足不进冷却
func _activate() -> bool:
	return false

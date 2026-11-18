class_name TimeEconomy
extends RefCounted

# 服务器负责 Beta 对战的时间颗粒奖励。击败或伤害其他玩家、破坏地形均可获得时间颗粒。
# 客户端先以服务器快照中的余额和透支状态为准，再预测本地输入造成的消耗和后续恢复。

var rules: Dictionary
var rewind_seconds: float
var accounts: Dictionary[int, GrainAccount] = {}


func _init(options: Dictionary, roles: Array = []) -> void:
	rules = TimeRules.normalized(options)
	rewind_seconds = minf(rules["cap"] / rules["rewind_burn"], 15.0)
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = GrainAccount.new(rules["initial"], rules["cap"], rules["window"],
				rules["regen"], rules["window"])

func restore_account(role: int, state: Array) -> void:
	add_role(role)
	accounts[role].restore_state(state)


func advance(players: Dictionary, inputs: Dictionary) -> void:
	for role: int in inputs:
		step_haste(players[role], inputs[role], ActorStep.DT)
	tick(ActorStep.DT)

func step_haste(player: Player, record: Array, delta: float) -> void:
	player.personal_haste_mult = 1.0
	var held: int = record[ActorInput.HELD]
	if player._controls_locked or player.sim_downed or player.rewinding \
			or (held & (ActorInput.BIT_HASTE | ActorInput.BIT_REWIND)) != ActorInput.BIT_HASTE:
		return
	var account: GrainAccount = accounts[player.role]
	if account.can_spend():
		account.spend(delta, rules["haste_burn"])
		player.personal_haste_mult = rules["haste_mult"]


## 恢复量按经过的时间计算，先用于偿还透支，剩余部分再补充短期额度。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role: int in accounts:
		accounts[role].regen(delta)


## 击杀对手时，击杀者获得相当于对手当前余额一定比例的时间颗粒。比例由房间设置决定。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	accounts[killer].deposit(int(accounts[victim].balance * rules["kill_ratio"]))


## 伤害奖励等于对其他玩家造成的有效伤害乘以房间配置的每点奖励。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	accounts[attacker].deposit(damage * rules["damage_gain"])


## 地形破坏奖励按实际破坏的子格数计算，每个子格边长为 16 像素。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	accounts[role].deposit(count * rules["block_gain"])


func state_payload() -> Dictionary[int, Array]:
	var states: Dictionary[int, Array] = {}
	for role: int in accounts:
		states[role] = accounts[role].capture_state()
	return states

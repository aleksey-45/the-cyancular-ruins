class_name PersonalTime
extends MatchTime

var rules: Dictionary
var rewind_seconds: float
var accounts: Dictionary[int, GrainAccount] = {}
var histories: Dictionary[int, TimeHistory] = {}


func _init(options: Dictionary, roles: Array = []) -> void:
	rules = options
	rewind_seconds = minf(rules["cap"] / rules["rewind_burn"], 15.0)
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	accounts[role] = GrainAccount.new(rules["initial"], rules["cap"], rules["window"],
			rules["regen"], rules["window"])
	histories[role] = TimeHistory.new(rewind_seconds)

func remove_role(role: int) -> void:
	accounts.erase(role)
	histories.erase(role)

func account_for(role: int) -> GrainAccount:
	return accounts[role] if role != 0 else null

func reset_history(role: int) -> void:
	histories[role] = TimeHistory.new(rewind_seconds)

func advance(combat: CombatSimulator, inputs: Dictionary, at: int) -> void:
	var reversing: Array[int] = []
	for role: int in combat.players:
		var player := combat.players[role]
		var history := histories[role]
		var input: Array = inputs[role]
		if int(input[ActorInput.HELD]) & ActorInput.BIT_REWIND and history.can_rewind() \
				and accounts[role].can_spend() and not player._controls_locked and not player.sim_downed:
			player.rewinding = true
			accounts[role].spend(ActorStep.DT, rules["rewind_burn"])
			reversing.append(role)
		else:
			if player.rewinding:
				player.rewinding = false
				inputs[role] = ActorInput.neutral(input[ActorInput.AIM])
			history.record(ActorStep.DT, at, _sample.bind(combat, player))
		_step_haste(player, inputs[role])
	for role: int in reversing:
		var sample := histories[role].backward(ActorStep.DT)
		combat.players[role].rewind_state(sample[TimeHistory.Sample.ACTOR], false)
		combat.restore_projectile_motion(sample[TimeHistory.Sample.ATTACKS])
	for account: GrainAccount in accounts.values():
		account.regen(ActorStep.DT)

static func _sample(combat: CombatSimulator, player: Player) -> Array:
	return [player.capture_state(), combat.capture_projectiles(player.role, true)]

func restore(checkpoint: Dictionary) -> void:
	var states: Dictionary = checkpoint.accounts
	var samples: Dictionary = checkpoint.histories
	for role: int in accounts.keys():
		if not states.has(role):
			remove_role(role)
	for role: int in states:
		if not accounts.has(role):
			add_role(role)
		accounts[role].restore_state(states[role])
		histories[role].restore(samples[role])

func _step_haste(player: Player, record: Array) -> void:
	player.personal_haste_mult = 1.0
	var held: int = record[ActorInput.HELD]
	if player._controls_locked or player.sim_downed \
			or (held & (ActorInput.BIT_HASTE | ActorInput.BIT_REWIND)) != ActorInput.BIT_HASTE:
		return
	var account: GrainAccount = accounts[player.role]
	if account.can_spend():
		account.spend(ActorStep.DT, rules["haste_burn"])
		player.personal_haste_mult = rules["haste_mult"]


## 击杀对手时，击杀者获得相当于对手当前余额一定比例的时间颗粒。比例由房间设置决定。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	accounts[killer].deposit(int(accounts[victim].balance * rules["kill_ratio"]))


## 伤害奖励等于对其他玩家造成的有效伤害乘以房间配置的每点奖励。
func award_damage(attacker: int, damage: int) -> void:
	accounts[attacker].deposit(damage * rules["damage_gain"])


## 地形破坏奖励按实际破坏的子格数计算，每个子格边长为 16 像素。
func award_blocks(role: int, count: int) -> void:
	accounts[role].deposit(count * rules["block_gain"])


func capture() -> Dictionary:
	var balances := {}
	var samples := {}
	for role in accounts:
		balances[role] = accounts[role].capture_state()
		samples[role] = histories[role].capture()
	return {"accounts": balances, "histories": samples}

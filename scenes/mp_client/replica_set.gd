class_name ReplicaSet
extends RefCounted

## 远端玩家副本集合:懒建 / 拆 / 消费世界快照 / 刷头顶 ID 与血条(大乱斗与 3v3 共用;1v1 只有一个固定副本,不走本件)。
## 形状是组合不是继承:宿主 bind() 把 `_replicas` 字典(同一份引用)、取色 Callable、可选的新建补配 Callable 交进来,
## 自己只留 `_on_snapshot_world` / `_process` 等委托口。节点名必须是 ReplicaP%d —— 真链路探针按名取。
## 宿主的 `_replicas` 字段刻意留在宿主上:team_match_watcher 直接读 game._replicas 数副本个数。

const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")
const LABEL_SCRIPT := preload("res://ui/factory/world_label.gd")
const HP_BAR_OFFSET := Vector2(0.0, -116.0)   # 血条中心相对副本原点的偏移

var _client: Node = null
var _replicas: Dictionary = {}     # role(int) -> PlayerReplica;★ 宿主持有的同一份字典
var _tint_of: Callable = Callable()   # role -> Color(大乱斗 = 色板;3v3 = 队色)
var _on_created: Callable = Callable()   # (replica, role) -> void:新建后的模式专属补配(3v3 幽灵层)
var _id_labels: Dictionary = {}    # role(int) -> WorldLabel(含自己)
var _hp_bars: Dictionary = {}      # role(int) -> EnemyHpBar(仅他人,设置开启时)


## 绑定宿主(同一份 `_replicas` 引用)与两个 Callable;`on_created` 省略 = 无补配。
func bind(client: Node, replicas: Dictionary, tint_of: Callable,
		on_created: Callable = Callable()) -> void:
	_client = client
	_replicas = replicas
	_tint_of = tint_of
	_on_created = on_created


## 懒建 role 的副本并返回它(已存在且有效则直接返回)。快照里出现才建:大乱斗对手数不定,3v3 的 role 号也可能不连续(最小空闲号 + 退房留空洞)。
func ensure(role: int) -> Node:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return _replicas[role]
	var replica: Node2D = REPLICA_SCENE.instantiate()
	replica.name = "ReplicaP%d" % role
	_client._world.add_child(replica)
	_replicas[role] = replica
	ensure_label(role)
	var col: Color = _tint_of.call(role)
	_client._apply_tint(replica.get_node_or_null("AnimatedSprite2D"), col)
	if _on_created.is_valid():
		_on_created.call(replica, role)
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_client._world.add_child(bar)
		_hp_bars[role] = bar
	refresh_labels()
	return replica


## 拆掉 role 的副本 / 头顶 ID / 血条(离开快照的玩家从这儿消失)。
func remove(role: int) -> void:
	if _replicas.has(role):
		var r: Node2D = _replicas[role]
		# ★ 先收视效再 free 副本:残影宿主挂在 _world、不在副本子树里,只 free 副本会永久留下它们。
		_client._time_fx_replica_rewind_off(r)
		if is_instance_valid(r):
			r.queue_free()
		_replicas.erase(role)
	if _id_labels.has(role):
		var l: Node = _id_labels[role]
		if is_instance_valid(l):
			l.queue_free()
		_id_labels.erase(role)
	if _hp_bars.has(role):
		var b: Node = _hp_bars[role]
		if is_instance_valid(b):
			b.queue_free()
		_hp_bars.erase(role)
	refresh_labels()


## 消费一条世界包:按 players 懒建/拆副本、套 apply_snapshot、刷血条(掉线者从快照消失即一并拆掉)。
## ★ 自己那份刻意不消费:C2 下本地玩家由引擎自步进,权威整态走本人包;写进来 = 每帧强写 = 橡皮筋。
func apply_world_snapshot(world: Dictionary) -> void:
	var local: Node2D = _client._local
	if local == null:
		return
	var snap_tick := int(world.get("tick", 0))
	if snap_tick < _client._last_snap_tick:
		return
	_client._last_snap_tick = snap_tick   # 输入包的 st 字段读宿主这份(两模式共用)
	var players_snap: Dictionary = world["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role != PvpSession.role:
			var r := ensure(role) as Node2D
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, local.global_position, snap_tick)
				r.set_meta("haste", bool(data.get("haste", false)))   # Beta:他人加速视效
				r.set_meta("rewind", bool(data.get("rewind", false)))   # Beta:他人回溯视效
				r.set_meta("trail", data.get("trail", []))
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
					# 线上 hp 已钳到 0:倒地尸体不显示血条,否则读成"残血还活着"。
					(_hp_bars[role] as Node2D).visible = not bool(data.get("downed", false))
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			remove(int(role_str))


## 建 role 的头顶 ID 节点(已建 / 无世界则什么都不做)。自己那颗在昵称到达时建,不随副本懒建。
func ensure_label(role: int) -> void:
	if _client._world == null or _id_labels.has(role):
		return
	var lbl: Node2D = LABEL_SCRIPT.new()
	_client._world.add_child(lbl)
	_id_labels[role] = lbl


## 把昵称与着色重刷到全部头顶 ID 上(没有名字的用兜底文案;自己那颗兜底用玩家名)。
func refresh_labels() -> void:
	var names: Dictionary = _client._names
	for role in _id_labels:
		var nm := str(names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(names.get(role, PvpSession.player_name))
		var col: Color = _tint_of.call(int(role))
		(_id_labels[role] as Node2D).set_label(nm, col)


## 每帧把头顶 ID / 血条贴到对应玩家(自己那颗跟本地玩家,其余跟副本)。head_offset 由宿主给。
func follow(head_offset: Vector2) -> void:
	var local: Node2D = _client._local
	for role in _id_labels:
		var target: Node2D = local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + head_offset
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + HP_BAR_OFFSET

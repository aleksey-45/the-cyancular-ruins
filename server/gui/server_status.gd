class_name ServerStatus
extends RefCounted

# 服务端控制台的数据层:把「大厅侧能证明的事实」归一成面板可直接渲染的快照。纯静态、零 autoload。
# ★ 为什么单独一个文件、且只吃纯字典:大厅里只有 LobbyRooms 知道房间,而 lobby_rooms.gd 引用 NetBus
#   ⇒ -s 冒烟里编译不过(spec §6.1)。故本文件**不引用 LobbyRooms**:字段搬运在 lobby_snapshot.gd,
#   判据(这里)才可被冒烟钉住。
# ★★ 局中房间的 players 一定是空的(成员已转连 worker)⇒ 人数必须按**冻结的 roster**算。
#   拿 players.size() 会把每一间正在打的房显示成「0 人」。
# ★ 房数 / 端口占用 / worker 存活是三个**独立**的量:端口归还延迟(1v1 120s / 大乱斗·3v3 360s)
#   让「房没了但端口还占着」成为常态,不许互相推导。

const WL := preload("res://server/lobby/worker_launcher.gd")

const STATE_WAITING := "waiting"       # 未开局:players 表可信
const STATE_IN_MATCH := "in_match"     # 已开局、worker 在(或还没拉起)
const STATE_STALE := "stale"           # 已开局、worker 已退出 ⇒ ≤30s 内被回收梯收掉


# rooms / ports 的元素形状见 spec §6.1。★ 返回的 rooms **顺序与输入一致**(面板按下标取)。
static func build(rooms: Array[Dictionary], ports: Array[Dictionary], now_unix: float) -> Dictionary:
	var out_rooms: Array[Dictionary] = []
	var n_waiting := 0
	var n_in_match := 0
	var lobby_players := 0
	for r in rooms:
		var entry := r.duplicate()
		var port := int(r.get("worker_port", 0))
		var pid := int(r.get("worker_pid", 0))
		var alive := _alive_of(ports, port)
		var started := bool(r.get("in_match", false))
		var roster: Array = r.get("roster", [])
		# ★ 与 room_manager._match_over 同口径:port<=0 或 pid<=0 = 还没拉起,一律**不算结束**
		#   (否则开局那一瞬会被判成 stale,面板会闪一条红字)。
		var state := STATE_WAITING
		if started:
			state = STATE_STALE if (port > 0 and pid > 0 and not alive) else STATE_IN_MATCH
		if state == STATE_WAITING:
			n_waiting += 1
			lobby_players += int(r.get("players", 0))
		else:
			n_in_match += 1
		entry["state"] = state
		entry["age_sec"] = maxf(0.0, now_unix - float(r.get("created_at", now_unix)))
		entry["worker_alive"] = alive
		entry["online_known"] = (state == STATE_WAITING)
		# ★ 局中人数按冻结名单;只有等待中的房 players 表才可信。
		entry["players"] = int(r.get("players", 0)) if state == STATE_WAITING else roster.size()
		out_rooms.append(entry)

	var workers_alive := 0
	for p in ports:
		if bool(p.get("alive", false)):
			workers_alive += 1

	return {
		"counts": {
			"rooms": out_rooms.size(),
			"waiting": n_waiting,
			"in_match": n_in_match,
			"lobby_players": lobby_players,
			"workers_alive": workers_alive,
			"ports_used": ports.size(),
			# ★ 单一来源:不写 500。
			"ports_total": WL.WORKER_PORT_SPAN,
		},
		"rooms": out_rooms,
		"ports": ports.duplicate(),
	}


# 该端口是否真的有一个活着的 worker(port<=0 ⇒ false:还没拉到)。
static func _alive_of(ports: Array[Dictionary], port: int) -> bool:
	if port <= 0:
		return false
	for p in ports:
		if int(p.get("port", -1)) == port:
			return bool(p.get("alive", false))
	return false


# ── 面板用的纯判据 ──────────────────────────────────────────────────────────
# ★ 为什么住在这里:面板是 Node、还引用 NetBus,`-s` 冒烟碰不得;`-s` 下只有 autoload-free 的
#   纯函数可测。故判据留在这儿,面板与 LobbyRooms 只做查表/转发(否则就是第二份真相)。

# 房间行的键:**必须带 kind**。三张注册表的 4 位房号空间**只在各自表内唯一**,
# 只按房号键时"1v1 的 4821"会覆盖"大乱斗的 4821":一行被写两次、另一行永远高亮不了,
# 点任意一行都会选中先收集到的那间 ⇒ 关房时 (code,kind) 复核也会"通过"却关错局。
static func row_key(kind: String, code: String) -> String:
	return "%s/%s" % [kind, code]


# 关房确认是否成立:武装时的目标必须**仍**是当前选中的目标。
# ★ 从武装到执行之间用户可以改选别行 —— 不比对就是"武装 A、关掉 B"。
static func can_close(armed_code: String, armed_kind: String,
		sel_code: String, sel_kind: String) -> bool:
	return armed_code != "" and armed_code == sel_code and armed_kind == sel_kind


# 大乱斗 / 3v3 的房主昵称。★ 等待中的房 roster **还没冻结**(只在开局那一刻冻),
# 只能从 host_peer + 昵称表取;局中 players 已空,只能读冻结名单里的 host_role。
static func host_of(in_match: bool, host_peer: int, host_role: int, frozen: Array,
		live_names: Dictionary) -> String:
	if not in_match:
		return str(live_names.get(host_peer, "玩家"))
	for e in frozen:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("role", 0)) == host_role:
			return str((e as Dictionary).get("name", "玩家"))
	return "玩家"


# 名单侧展示数据:等待中 = players + 昵称表(实时);局中 = 冻结快照(players 已空)。
static func roster_of(in_match: bool, frozen: Array, players: Array, roles: Dictionary,
		live_names: Dictionary) -> Array:
	var out: Array = []
	if in_match:
		for e in frozen:
			if typeof(e) == TYPE_DICTIONARY:
				out.append({"role": int((e as Dictionary).get("role", 0)),
						"name": str((e as Dictionary).get("name", "玩家"))})
		return out
	for pid in players:
		out.append({"role": int(roles.get(pid, 0)), "name": str(live_names.get(pid, "玩家"))})
	return out

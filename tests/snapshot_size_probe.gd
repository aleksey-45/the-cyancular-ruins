extends Node

# 快照体积探针(场景模式):把「一份快照到底多少字节、随人数怎么长」从估算变成实测。
# 跑法:
#   "$GODOT" --headless --path . res://tests/snapshot_size_probe.tscn
# 期望:末行 "SNAPSHOT SIZE PROBE: ALL-OK"。
#
# 存在理由:`docs/royale-soak-2026-09-12.md` §2.2 实测「每人每快照 ≈0.96 KB、服务器上行 ∝ N²」,
# 但那是**整包**读数 —— 设计「本人包 / 世界包」拆分时需要知道这 0.96 KB 里
# 多少是 c2 权威整态、多少是渲染散字段。本探针就量这个拆分,并给出 N=2..8 的折算表。
#
# 做法:真实例化一具 Player.tscn(autoload 在场景模式下就绪),取它的 capture_state() 当 c2;
# 按 `server/match_host.gd:_broadcast_snapshot` 的**逐字**字段表拼两种 dict,
# 再用 var_to_bytes() 量序列化体积(与 RPC 实际打包同一套变体编码)。
#
# ⚠ 判据 grep 文本 "SNAPSHOT SIZE PROBE: ALL-OK"(不只看退出码)。
# ⚠ 本探针只量「载荷」,不含 ENet 分片头/RPC 方法名等固定开销(见末尾打印的备注)。

const MTU := 1400          # ENet 默认 MTU
const FRAG_HEADER := 8     # 分片包每片大致头部开销(粗估,用于折算片数)
const SNAP_HZ := 60        # SNAPSHOT_INTERVAL = 1/60

var _failures: Array[String] = []
var _player: Node = null


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[size]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[size]   ✗ %s" % msg)


func _ready() -> void:
	var ts: PackedScene = load("res://scenes/player/Player.tscn")
	_player = ts.instantiate()
	add_child(_player)          # _ready 跑完(weapons.equip("1") 等)再取 capture_state
	await get_tree().physics_frame

	var entry := _entry_current()
	var render_only := _entry_render_only()
	var c2_only := _entry_c2_only()

	var sz_entry := var_to_bytes(entry).size()
	var sz_render := var_to_bytes(render_only).size()
	var sz_c2 := var_to_bytes(c2_only).size()

	print("[size] 单玩家条目(现方案,渲染散字段 + c2 整态)= %d B" % sz_entry)
	print("[size] 其中:渲染散字段 = %d B, c2 权威整态 = %d B" % [sz_render, sz_c2])
	print("[size] c2 字段数 = %d, 渲染字段数 = %d" % [
			(_entry_c2_only() as Dictionary).size(), (render_only as Dictionary).size()])

	_check(sz_entry > 0, "条目序列化体积可测(%d B)" % sz_entry)
	# 拆分必须自洽:两部分之和应当就是整条目(同一套编码,键不重叠)
	_check(sz_entry >= sz_render + sz_c2 - 64,
			"渲染 + c2 之和不超整条目(拆分的键表覆盖完整)")

	var thin := _entry_world_thin()
	var sz_thin := var_to_bytes(thin).size()
	print("[size] 世界包瘦身版(短键 + 去掉副本不消费的 vel/waterproof)= %d B/人" % sz_thin)

	print("[size] ── N=2..8 折算(单帧载荷 / 每秒单端下行 / 服务器每秒上行)──")
	print("[size]  N |   现方案:单帧载荷  单端下行  服务器上行 | 新方案:本人包  世界包  单端下行  服务器上行")
	for n in range(2, 9):
		_report(n, sz_entry, sz_render, sz_c2)

	_report_mtu(sz_render, sz_c2, sz_thin)

	print("[size] 备注:以上均为**载荷**字节(var_to_bytes),不含 ENet 分片头与 RPC 方法名等固定开销;")
	print("[size]      分片折算按 MTU=%d / 每片头 %d B 粗估。" % [MTU, FRAG_HEADER])

	# 注:退出时 Godot 会报少量 "leaked at exit"(在 _ready 里 quit 的探针都这样,与其它探针一致)。
	# **不要**在这里显式 free 那具临时玩家 —— 实测反而从 2 条涨到 18 条(释放时机在树内不对)。
	if _failures.is_empty():
		print("SNAPSHOT SIZE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SNAPSHOT SIZE PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


# ── 三种 dict:逐字对照 match_host._broadcast_snapshot 的字段表 ──

func _render_fields() -> Dictionary:
	# 渲染/副本消费所需的散字段(不含 c2):见 _broadcast_snapshot 的 snap["players"][role]
	var p := _player
	return {
		"pos": p.global_position,
		"vel": p.velocity,
		"facing": p.get_facing(),
		"pose": p.state,
		"weapon": p.weapons.current_slot_int(),
		"hp": p.hp,
		"waterproof": p.waterproof,
		"downed": p.is_downed(),
		"aim": p.get_current_aim_dir(),
		"previewing": false,
	}


func _entry_render_only() -> Dictionary:
	var d := _render_fields()
	d["ack_seq"] = 0        # ack 只对本人有意义,单列出来便于比较
	return d


# 世界包瘦身版:①短键(协议两端同改,值不变)②去掉副本 apply_snapshot 根本不读的 vel/waterproof。
# 唯一消费 vel 的是 player.apply_server_snapshot —— 那条路已在 C2 迁移(批次 5,2026-09-12)删除,
# 故世界包不必再带 vel。
# pose/facing/weapon/aim/hp/downed/previewing 全部保留(副本 + 头顶血条在用);previewing 仍按
# "只发不用"保留(它是日后换成音效/轮廓提示的接点,见 player_replica 的注释)。
func _entry_world_thin() -> Dictionary:
	var p := _player
	return {
		"p": Vector2i(roundi(p.global_position.x), roundi(p.global_position.y)),
		"f": p.get_facing(),
		"s": p.state,
		"w": p.weapons.current_slot_int(),
		"h": p.hp,
		"d": p.is_downed(),
		"a": p.get_current_aim_dir(),
		"v": false,
	}


func _entry_c2_only() -> Dictionary:
	return (_player.capture_state() as Dictionary).duplicate()


func _entry_current() -> Dictionary:
	var d := _render_fields()
	d["ack_seq"] = 0
	d["c2"] = _entry_c2_only()
	return d


# ── 折算 ──

func _kb(b: int) -> String:
	return "%.2fKB" % (float(b) / 1024.0)


func _report(n: int, sz_entry: int, sz_render: int, sz_c2: int) -> void:
	# 现方案:一份含全部 N 人(c2)的 dict,逐 peer 各 rpc_id 一次 → 服务器序列化 N 次
	var cur_frame := n * sz_entry
	var cur_server_up := float(cur_frame * SNAP_HZ * n)      # 逐 peer 各发一份
	var cur_client_down := float(cur_frame * SNAP_HZ)

	# 新方案:①本人包 = 自己的 c2 + ack(定向 rpc_id,每人一份,大小 = sz_c2 + ack)
	#         ②世界包 = 全部 N 人的渲染散字段(构造一次,广播一次)
	# 服务器上行 ≈ N × (c2 包) + 1 × (世界包)
	var own_pkt := sz_c2 + 16                                 # +ack/seq/方法开销余量
	var world_pkt := n * sz_render
	var new_server_up := float((n * own_pkt + world_pkt) * SNAP_HZ)
	var new_client_down := float((own_pkt + world_pkt) * SNAP_HZ)

	print("[size] %3d | %8s %8s %9s | %7s %7s %8s %9s" % [
			n, _kb(cur_frame), _kb(int(cur_client_down)), _kb(int(cur_server_up)),
			_kb(own_pkt), _kb(world_pkt), _kb(int(new_client_down)), _kb(int(new_server_up))])


func _report_mtu(sz_render: int, sz_c2: int, sz_thin: int) -> void:
	print("[size] ── 超 MTU 折算(ENet MTU=%d;超过即分片不可靠包,丢一片=整帧丢)──" % MTU)
	var thinned_total := 0
	var plain_total := 0
	for n in range(2, 9):
		var cur := n * (sz_render + sz_c2 + 16)
		var world := n * sz_render
		var world_thin := n * sz_thin
		if _frags(world) == 1:
			plain_total += 1
		if _frags(world_thin) == 1:
			thinned_total += 1
		print("[size]  N=%d: 现方案单帧 %s → %d 片 | 世界包 %s → %d 片 | 瘦身后 %s → %d 片" % [
				n, _kb(cur), _frags(cur),
				_kb(world), _frags(world), _kb(world_thin), _frags(world_thin)])
	print("[size] 世界包仍在 1 片内的人数档:原字段表 %d/7,瘦身后 %d/7" % [plain_total, thinned_total])


func _frags(payload: int) -> int:
	if payload <= MTU:
		return 1
	var usable := MTU - FRAG_HEADER
	return int(ceil(float(payload) / float(usable)))

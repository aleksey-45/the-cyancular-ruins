class_name PvpMatchClient
extends Node2D

# PvP 对局客户端的**共享基类**(1v1 `pvp_client` / 大乱斗 `royale_game` 都 extends 它)。
#
# ★ 为什么:两个客户端本是一份代码按「对手 1 个 / N 个」叉开的,叉开时**复制**了整份实现 ——
#   于是同一处修正要改两遍,漏一处**不报错**(表现是"1v1 里好了、大乱斗里没变",或反过来)。
#   2026-09-14 收口:凡是两个模式**语义相同**的都上提到这里;子类只留真正的差异。
#
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像")。本步上提的 7 个函数**代码逐字相同**,
#   合计 58 行,其中 `_physics_process` 是 C2 循环的心脏(3.1 把组包收进 pack_record 之后两份就
#   一模一样了)。
#
# ★ **子类保留的差异**(刻意不在这里):
#   · 对手副本是 1 个固定(`_remote_replica`)还是 N 个按 role 动态(`_replicas`)—— 这决定了
#     `_process` / `_on_snapshot_world` / `_on_round_state` / `_apply_peer_hues` 等的形状;
#   · HUD 类(`PvpHud` vs `RoyaleHud`)、退场是否额外锁 `_match_ended`、`_unhandled_input` 的自杀键;
#   · `_ready`(差异最大,各建各的世界/副本/HUD)。
#   要再上提一批,先按同样的口径量一遍差异(剔注释后逐行 diff),别凭印象搬。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

# ── 共享状态(两个模式同名同义;子类不要再声明一次)──
var _local: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹/TileHitFx 副本挂这里)
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/pvp-c2-retrospective.md
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0

func _apply_tint(body: Node, hue_deg: float) -> void:
	var canvas := body as CanvasItem
	if canvas == null or is_zero_approx(hue_deg):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", hue_deg)
	canvas.material = mat

func _correct_local_spawn() -> void:
	if _local == null or not _round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	_local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)

func _on_hit_confirm(shooter_role: int, _victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

func _apply_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	if _local != null:
		_local.weapons.set_enabled_slots(disabled)

func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)

func _on_remote_tile_destroyed(cell: Vector2i) -> void:
	if _world == null:
		TileDefs.damage_tile(cell, 999999, "explosion")
		return
	# 取被拆砖原纹理(决定碎片颜色:树叶绿/树干棕),再清砖
	var tex := 0
	var grid := MazeGenerator.current_grid
	if not grid.is_empty() and cell.y >= 0 and cell.y < grid.size():
		var row: Array = grid[cell.y]
		if cell.x >= 0 and cell.x < row.size():
			tex = MazeGenerator.texture_of(int(row[cell.x]))
	TileDefs.damage_tile(cell, 999999, "explosion")
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	# 周期测延迟(右下角 HUD)
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _rollback != null:
		if _have_prev_seq:
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: InputSource = _local.input_source
	# 位打包收在 NetworkInputSource.pack_record(协议**编码端**唯一来源;解码端本来就只有一份)。
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := NetworkInputSource.pack_record(src, _input_seq, aim)
	# 滚轮切枪:目标槽位随输入包上行(滚轮事件不在协议里,只本地切会被快照切回)
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用

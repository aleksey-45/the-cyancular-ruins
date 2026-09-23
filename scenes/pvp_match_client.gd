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
const LaserVisual := preload("res://core/present/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

# ── 共享状态(两个模式同名同义;子类不要再声明一次)──
var _local: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹/TileHitFx 副本挂这里)
var _level0: Node = null  # 世界(Level0):补态那一路要还原可破坏砖(见 _on_match_sync)
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/pvp-c2-retrospective.md
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
# ── 网络统计读数(2026-09-22 诊断用,★ 默认关)──────────────────────────────
# 开关:`-- --netstat`。★ 必须写在 `--` 之后 —— 与 `server_main` 的 `--worker` 同款口径;
# 写在 `--` 前面会被 Godot 丢掉、**静默失效**。默认关 ⇒ 生产行为逐字不变(只多一次布尔判断)。
# 一次打一行,四个量(后三个是判据,不是装饰):
#   gap   = `_input_seq - 最后收到的 ack` = 本端已发、服务器还没确认的包数
#           ⇒ 「RTT + 服务端积压」的总和(×16.67ms 就是端到端滞后)
#   ping  = `NetBus.ping_ms`(= HUD 右下角那个数,EWMA 平滑的**纯网络** RTT)
#   积压  = gap×16.67 − ping ⇒ **扣掉网络之后**还剩多少是服务器没来得及消费的
#           (CLAUDE.md 把「每 tick 只消费 1 包、无上限无丢弃」登记为「越玩越卡」的第一嫌疑点;
#            本条就是判它**成不成立**的量:稳定贴着 0 = 无罪,一路涨 = 实锤)
#   回滚  = `rollback_count()` 的**每秒增量** ⇒ 本地预测被拉回的频率
#           (「按了键角色被拽回去」的直接量;恒为 0 也可能是哑火,见 on_authoritative 的 ack 闸)
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_prev_rb := 0
var _last_ack := 0
var _netstat_steps := 0     # 两次打印之间的物理步数(=物理步/秒,因为本函数每物理步调一次)
# MATCH_OVER 之后回菜单途中:忽略对手断线播报;也让输入锁把它算作一维(见 _refresh_input_lock)。
# 1v1 里它只在 MATCH_OVER 那一刻置 true;大乱斗同。
var _match_ended := false
# 暂停菜单是否开着(PvP 下菜单不暂停树,靠它锁本地输入;见 _refresh_input_lock)
var _menu_open := false
var _result: MatchResult = null             # 结算页(挂载一次,由 _show_result 建)
var _last_round_state: Dictionary = {}      # 最近一条 round_state(结算载荷的输入之一)

# 玩家本体精灵(player.png)的**主色**(RGB)。"把身体染成某个颜色"要拿它当基准去做比值。
# ★ 数值是**实测**的不是拍的(2026-09-19):主色 `#639BFF`,占 12987 个不透明像素里的 10875(83.6%);
#   次色 `#5585D9` 是它的暗调同色。复测办法:按 alpha>200 过滤 player.png 的全部像素,
#   取出现次数最多的那个 RGB。
# ★ 换 sprite 素材要重测这一行 —— 它错了不报错,只是队色会**整体偏色**(整队一起偏,所以
#   "谁是谁"照旧分得出,更容易漏)。三个分量都非 0,故下面那句比值除法不需要额外兜底。
const BODY_BASE_COLOR := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)   # #639BFF


# 通用身体染色:只给角色本体 AnimatedSprite2D 上色(武器/预瞄线不染)。
# 两条互斥的路,按 `color_override` 是否存在二选一:
#   · `color_override` 非透明 = **modulate 比值**(见下)。用户:**3v3 队色** + **1v1 的 P2**
#     (`pvp_game._apply_p2_tint` 传的就是队 2 那个 token ⇒ 两处同色是结构性的)。
#   · 默认(大乱斗 / 3v3 的**个人色相**)= **色相旋转**:挂 `player_p2_hue.gdshader`,
#     `hue_deg` 是旋转量,0 = 不改色(故本助手可重复调用)。
#
# ★ 队色为什么是"modulate 比值"而不是"直接乘队色"(brief 给的是后者 —— 二选一,这里选前者
#   但**改了算法**,理由是实测的):`modulate` 是**乘**,只能把身体压暗、改不了色相。本体主色是蓝
#   `#639BFF`,蓝 × 队色 ≠ 队色,"一眼看出谁是队友"会落空(当初拿旧队色实测:.superpowers/sdd/
#   `_t6_tint2.png` 第②列是一坨**灰紫**)。
#   改成 **`目标色 / 本体主色`** 这个**比值**就精确了:输出 = 主色像素 × 比值 = **恰好目标色本身**
#   (2026-09-19 复测:队 1 得到 `#639BFF` = `C_TEAM_A`,逐字节相等;当时队 2 的 token 是 `#63FFF3`,
#    同样是逐字节相等 —— 2026-09-20 队 2 的 token 改成 `#80F4FF`,比值随之变,链子不变,
#    渲染侧由 `tests/hue_tint_probe` 守卫 B/C 钉住)。
#   队色因此与头顶 ID / 小地图点位**同源同一个常量**,不存在"身体是派生色、柱子上是原色"。
# ★ 队 2 的比值有分量 > 1(g = 244/155 ≈ 1.574、r ≈ 1.293)—— 这是**有意的**:
#   `CanvasItem.modulate` 收 >1 的值,实测在 `rendering/mobile`(Forward Mobile)下原样生效。
#   队 1 的比值恰为 (1,1,1)(队色 = 本体主色)⇒ 队 1 的身体就是默认蓝。
# ★ 为什么队色(以及 1v1 的 P2)仍不走 `player_p2_hue.gdshader`(试过):hue 旋转数学上是对的,
#   但走那条路要先知道目标色的色相、再反推该转多少度,而"输出 == 这个 token"只是数值上逼近;
#   比值法是**结构性**成立的(输出恒等于 token 本身)。
#   ★ 另有一条硬理由(2026-09-20):hue 旋转**保持饱和度/亮度不变**,而本体主色是 S61 V100
#      ⇒ 它**表达不了** S50 这类目标色(用户新选的青 `#80F4FF` 正是 H185 S50 V100)。
#   (那个 shader 的"纹理乘两次"bug 2026-09-19 已修 —— 它当年让 hue 旋转结果被逐通道乘积压灰;
#    它现在是**个人色相**那条唯一的路,仍在生产里。)
func _apply_tint(body: Node, hue_deg: float, color_override: Color = Color(0, 0, 0, 0)) -> void:
	var canvas := body as CanvasItem
	if canvas == null:
		return
	# ① 队色(modulate 比值):精确染成 `color_override` 本身
	if color_override.a > 0.0:
		canvas.modulate = Color(color_override.r / BODY_BASE_COLOR.r,
				color_override.g / BODY_BASE_COLOR.g,
				color_override.b / BODY_BASE_COLOR.b)
		return
	# ② 色相旋转(1v1 / 大乱斗的既有效果);0 = 不改色
	if is_zero_approx(hue_deg):
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
	# ★★ 跨纪元的旧 ack **必须丢掉**(2026-09-17 整支审查的 C 项:重连后 `_acked` 被上一纪元的 ack 毒死)。
	#   机制:重连时服务器在 `_on_reclaim` 里把 `_ack_seq[role]` 归 0 重协商锚点,而客户端要到
	#   `_on_resumed` 才把 `_input_seq` 归零 —— 这中间(握手落地 → match_start 到达)它仍在用
	#   **断线前那个 seq 空间**发包 → 服务器下一 tick 消费到的就是那个大 seq、`_ack_seq` 当场被写回
	#   N+1 并立刻广播一条带它的快照;而那条快照(unreliable)落在 `_on_resumed` **刚重建**的
	#   rollback 上(`_acked` 从 0 起)→ `_acked` 被抬到一个新纪元追不上的高度,
	#   `PredictionRollback.on_authoritative` 的 `ack <= _acked` 把之后所有真实 ack(1,2,3…)全丢,
	#   直到客户端自己的 seq 爬过它 —— **断线前活了多久就哑多久**(探针实测 ~560 帧 ≈ 9s;一局中段
	#   可上万帧)。症状正是 `prediction_rollback.gd` 记过的那个静默退化:不报错、**回滚恒为 0**、
	#   `sync_soft_state` 不再被调用 → 背包/拾取不同步("地上的枪没了、手上也没多、还开不了火")。
	#   判据:**合法 ack 永不超过本端已发的 seq**(服务器只可能 ack 它消费过的包)→ 超过的一定是
	#   上一个 seq 空间的残留,丢掉即正确(那几条本来就该被 `_on_resumed` 的重置作废)。
	#   ★ 两侧的复位互为理由(服务端归 0 是为了客户端的 `_acked`,客户端重置是为了服务端的 0),
	#     只改一侧会得到镜像的同一个洞;守卫:`tests/reconnect_probe.tscn` 相①(去掉本行即红)。
	var ack := int(own.get("ack_seq", 0))
	if ack > _input_seq:
		return
	_last_ack = ack          # 网络统计读数用(诊断,默认关)
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(ack, c2)

# silent=true 用于"重连后补破坏态":那些砖是**掉线期间**被拆的,不是刚被拆的 ——
# 逐格播碎片会变成一屏不该有的粒子(而且几十格同时炸)。
func _on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void:
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
	if silent:
		return
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
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _rollback != null:
		if _have_prev_seq:
			# 贴身提示:只在**接触期**放宽容差(见 core/prediction_rollback.gd 的 contact_pos_tol)。
			# ★ 必须在 reconcile() 之前 —— 它是消费方。★ 漏了这一行 = **静默**退回 2px 容差,
			#   故 rollback_fidelity_probe 有一条源码守卫钉住它的位置与唯一性。
			_rollback.in_contact = _local.touching_player()
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: PlayerInput = _local.input_source
	# 位打包收在 PacketInputSource.pack_record(协议**编码端**唯一来源;解码端本来就只有一份)。
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := PacketInputSource.pack_record(src, _input_seq, aim)
	# 滚轮切枪:目标槽位随输入包上行(滚轮事件不在协议里,只本地切会被快照切回)
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	# ★ 只有真发得出去时才发:离场的三条路(ESC / MATCH_OVER / 对手离开)都会先 `NetBus.stop()`,
	#   而本场景到帧末才被换掉 —— 中间这一两帧 `rpc_id` 会打引擎错误
	#   (`Trying to call an RPC while no multiplayer peer is active`),包本来也发不出去。
	#   预测与记账照常走完(seq 照增),只是不上行 —— 不影响 seq 的单调性。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)
	# 地面武器:锚点 + 落点同步 + F 提示(纯本地表现,不参与预测)
	_tick_ground_weapons()
	# 本地视觉子弹撞到玩家 → 收掉(纯表现,见 _cull_bullet_contacts 的注释)
	_cull_bullet_contacts()
	# 网络统计读数(诊断,默认关)
	_netstat_tick(_delta)


# 网络统计读数:见 `_netstat` 的说明(2026-09-22 诊断用;`-- --netstat` 打开)。
# ★ 开关走 `OS.get_cmdline_user_args()` 且**懒查一次**(本类没有 `_ready` —— 三个子类各有一个,
#   在基类再加会被覆盖掉,静默失效)。
func _netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		_netstat = OS.get_cmdline_user_args().has("--netstat")
	if not _netstat:
		return
	# 本函数由 `_physics_process` 每物理步调一次 ⇒ 两次打印之间的调用次数就是**物理步/秒**。
	# 它显著高于渲染帧率 ⇒ 说明有物理追赶(catch-up),那会一次性发出成串输入包 —— 正是
	# 服务端队列被顶上去的形态。这一行是为了回答"headless 夹具是不是每帧跑多个物理步"
	# (若是,则夹具里测到的队列可能根本不在真实 60fps 对局里出现)。
	_netstat_steps += 1
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var gap := _input_seq - _last_ack
	var lag_ms := float(gap) * 1000.0 / 60.0
	var ping := NetBus.ping_ms
	var rb := 0
	if _rollback != null:
		rb = int(_rollback.rollback_count())
	var where := Vector2.ZERO
	if _local != null and is_instance_valid(_local):
		where = (_local as Node2D).global_position
	print("[netstat] seq=%d ack=%d gap=%d(滞后 %.0fms) | ping=%dms | 扣网后积压≈%.0fms | 回滚累计=%d (+%d/s) | pos=(%.0f,%.0f) | 物理步/秒=%d 渲染fps=%d"
			% [_input_seq, _last_ack, gap, lag_ms, ping, lag_ms - float(ping), rb, rb - _netstat_prev_rb,
			where.x, where.y, _netstat_steps, Engine.get_frames_per_second()])
	_netstat_steps = 0
	_netstat_prev_rb = rb


func _on_bullet_spawn(data: Dictionary) -> void:
	if _world == null:
		return
	var scene: PackedScene = load(data["scene"])
	if scene == null:
		return
	var b: BulletBase = scene.instantiate()
	b.setup(data["vel"].normalized(), data["speed"], data["range"], data["size"], data["color"], null)
	b.gravity_factor = data["gravity"]
	b.hit_damage = data["hit_damage"]
	b.hit_impact = data["hit_impact"]
	b.apply_damage = false   # 视觉副本:不裁决伤害
	if data["explodes"]:
		b.explodes = true
		b.direct_hit_damage = data["direct_damage"]
		b.fuse_time = data["fuse"]
		b.hit_fuse_time = data["hit_fuse"]
		b.explosion_radius = data["radius"]
		b.explosion_damage = data["expl_damage"]
		b.explosion_knockback = data["expl_knock"]
		if data.has("visual"):
			b.explosion_visual = load(data["visual"])
	b.global_position = data["pos"]
	_world.add_child(b)
	# ★ 视觉副本也要认射手:见 `_broadcast_bullet_spawn` 的注释(榴弹"出膛即炸")。
	#   指向**射手副本**而不是本地玩家 —— `BulletBase` 里凡是用 `shooter` 的地方都自带
	#   类型/分组守卫(见 `_wrap` 的 `is_in_group("player")` 与 `_check_player_contact`
	#   的 `n == shooter`),拿副本当射手不会破坏它们。
	b.shooter = _replica_for(int(data.get("shooter_role", 0)))
	# 敌方武器轨迹(设置开启时):轨迹线挂在视觉副本子弹上
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(b, data["color"])


# ── 本地视觉子弹撞到"该打的人" → 立刻消失(用户 2026-09-22:「画面效果看起来还是像穿透」)──
# **为什么需要这条**:客户端那颗子弹的 `collision_mask = 5`(地形 1 + 敌人层 4),而**对手在
# 客户端只是一具层 2 的幽灵体**(`player_replica._ghost`)**⇒ 物理上永远撞不到** —— 子弹从对手
# 身上穿过去、一直飞到撞墙或超射程;而服务器早已按半径裁决、扣了血、销毁了它那两颗。
# 玩家看到的因此是"伤害算到了,画面上却像穿透"。
#
# **判据用与服务器裁决同一个常量**:`BulletBase.PLAYER_HIT_RADIUS`(= `MatchHost.HIT_RADIUS`
# 引用的那一个)+ 同一套环面最短距离 ⇒ "子弹停在哪"与"服务器判在哪"是**同一个公式**算出来的,
# 不是凑出来的相似值(凑的话两者迟早漂)。
#
# ★ 只收**本地视觉副本**:`apply_damage == false`(客户端子弹都带这个标记;权威侧在服务器进程,
#   本类不在那儿跑)。权威裁决一个字都不受影响 —— 伤害永远由服务器说了算,这里只改画面。
# ★ **榴弹(`explodes`)不走这条**:它的引信/反弹由 `BulletBase._check_player_contact` 管,
#   在这里把节点收掉会把爆炸一起吞掉。
func _cull_bullet_contacts() -> void:
	for n in get_tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if _bullet_contact_target(b) != null:
			b.queue_free()   # 立刻:queue_free 在本帧绘制**之前**生效,不会多亮一帧


# 这颗视觉子弹此刻有没有贴上"该打的人";有则返回那个节点,否则 null。
# 候选 = `BulletBase.CONTACT_GROUPS`(player = 本地玩家;player_replica = 对手副本),
# 排掉射手本人 —— 与 `_check_player_contact` 同一候选集,再叠一层队别过滤(3v3 队友穿透)。
func _bullet_contact_target(b: BulletBase) -> Node2D:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for group in BulletBase.CONTACT_GROUPS:
		for n in get_tree().get_nodes_in_group(group):
			if n == b.shooter or not (n is Node2D):
				continue
			if not _bullet_hits_entity(b, n as Node2D):
				continue
			var d := GridPathfinder.toroidal_delta_px(b.global_position,
					(n as Node2D).global_position, w, h).length()
			if d < BulletBase.PLAYER_HIT_RADIUS:
				return n as Node2D
	return null


# 这颗视觉子弹能不能停在那个实体上。默认**能**(1v1 / 大乱斗:除了射手,谁都能挡)。
# 3v3 覆写:与射手同队的排掉 —— 规则 12「队友不互挡 + 子弹穿透队友」;
# 不覆写的话队友副本会把自己的子弹吃掉(与服务器裁决相反,且不报错)。
func _bullet_hits_entity(_b: BulletBase, _ent: Node2D) -> bool:
	return true


# 本地输入锁的单一口(三个维度:冻结期 / 菜单打开 / 结算后回菜单途中)。
# 2026-09-14 从两个子类合并:**大乱斗那版多一个 `_match_ended`** —— 合并后 1v1 也带上它。
# ★ 这是本步唯一的行为差异:1v1 在 MATCH_OVER 之后的那几秒里输入现在也被锁(此前没有)。
#   与 `_match_ended` 的语义一致(那段时间正在回菜单),且与大乱斗**同款** —— 属有意统一,不是顺手改。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)


# ── 结算页(2026-09-21):挂载与离场**三个模式共用**,各自只覆写 `_build_result_payload()` ──
# ★ 为什么在基类:三个客户端(`pvp_game` / `royale_game` / `team_game`)**本来就都**
#   `extends PvpMatchClient`,不存在"要动继承链"这件事。挂载/离场逐字同构,抄三份必然漂 ——
#   与本文件既有的 `_apply_peer_hues_or_team` / `_replica_for` 是同一个形状。
# ★★ 必须走**场景实例化**,不能用 `MatchResult.new()`:`layer = 150` **只写在
#   `ui/match_result.tscn` 里**(脚本不设 layer —— 三个现有 HUD 同款写法,层位值只有那
#   一处来源)。用 `.new()` 会拿到 CanvasLayer 默认的 **layer 1**,结算页画在 HUD(130)/
#   小地图(131) **下面**、压暗罩盖不住它们,而计划自己的类头注释却写着「盖住一切」。
#   ★ 这条有守卫:`tests/hud_declarative_probe` 走盘扫 `res://scenes/` 下每个 .gd,
#     出现 `MatchResult.new(` 即红。
const RESULT_SCENE := preload("res://ui/match_result.tscn")

# 结算页:玩家自己退(不再是 N 秒后自动回主菜单)。三个模式共用 —— 它们都 extends 本类,
# 各自只覆写 `_build_result_payload()`。
# ★★ **挂载一次、但每次都要刷新**(`if _result == null` 只包住"建 + 连线")。
#   写成 `if _result != null: return` 会把"挂载幂等"顺手变成"**更新也只一次**":
#   第二条 MATCH_OVER 载荷就永远到不了屏幕上,而 `MatchResult.show_result` 的清场重建
#   (`ui/match_result.gd` 的 remove_child→queue_free 那段)在生产里**一次都不会跑** ——
#   探针却直接调它、照绿。**探针比产品更绿**是这里最难发现的形状。
#   ★ 第二条载荷**可达**(不是假想):1v1 —— `server_main.gd` 在每次 reclaim 成功后重播当前
#     `round_state`,掉线重连的客户端就会收到第二条 MATCH_OVER;3v3 —— `team_host.gd` 的
#     `_finish_match()` 在战斗进行中直接把 PLAYING→MATCH_OVER,而倒地边沿检测在
#     `match _round_state:` **之前**且**不看状态** ⇒ MATCH_OVER 之后再死人会再广播一条
#     带新 `stats`/`mvp` 的终局载荷;`mark_disconnected` 那条同款。
func _show_result() -> void:
	if _result == null:
		_result = RESULT_SCENE.instantiate()
		add_child(_result)
		_result.leave_requested.connect(_leave_to_main_menu)
		# ★★ **挂载那一刻先用空载荷亮出来**,再折真载荷。顺序不可换 —— 这是"MATCH_OVER 之后
		#   永远有出路"那条不变量的安全网(2026-09-21 终审 I3)。
		#   要防的故障形状是:**`show_result()` 在它最后那句 `visible = true` 之前结束**。
		#   那时结算页停在 `_ready()` 末尾那句 `visible = false` 上 —— **看不见、ESC 也够不着**
		#   (它的 `_unhandled_input` 首行是 `if not visible: return`)、按钮也点不到;而此刻暂停
		#   菜单已被 MATCH_OVER 块销毁、K 键被 `_match_ended` 挡住 ⇒ 玩家**卡死在对局里**。
		#   ★ 可达形状(合成故障实测):载荷里混进**非字典的节** ⇒ `show_result` 里
		#     `_build_section(sections[i], …)` 的参数类型转换当场失败 ⇒ 整个 `show_result` 在
		#     `visible = true` **之前**结束。适配器改动 + 这页的"缺键一律取默认"口径之间,
		#     只差一个"某节不是字典"就能走到。今天没有人踩到,所以这是**安全网**不是活 bug。
		#   ★ 另一条**不**构成陷阱(实测,免得后人照直觉"修"错地方):`_build_result_payload()`
		#     内部抛错只让**它自己**当场结束,而它签名是 `-> Dictionary` ⇒ 隐式返回的 null 被强制
		#     转换成**空字典** ⇒ 退化成"可见但空"的结算页,出路仍在(实测 visible=true)。
		#   ⇒ 关键是"亮出来"必须排在任何可能把 `show_result()` 打断的活**之前**。放进
		#     `show_result()` 内部同样能挡住它自己那一段;放在这里则连"挂载之后、调用之前"那一小段
		#     也一起盖住(将来谁在中间插一句会抛错的代码,也不会退化回陷阱)。
		#   空载荷**抛不出错**:"空载荷不崩"是本页的硬要求(`tests/match_result_probe` ① 专钉),
		#   且它只做"赋文案 + 清场建节 + `visible = true`"三件事 ⇒ 可见、ESC 生效、
		#   "返 回 主 菜 单"按钮可用,三样退路当场到手。
		#   ★ 正常路径**看不到这个空态**:本函数一次跑完、两句之间没有 await,布局与绘制都在帧末,
		#     玩家看到的永远是下面那句填好的那份。
		_result.show_result({})
	_result.show_result(_build_result_payload())


# 结算页 -> 主菜单。★ 离开仍走 Level0.safe_change_scene —— 游戏世界含全量碰撞,
# 裸 change_scene_to_file 会同步 memdelete → 偶发原生段错误。
# ★ 防重入由 MatchResult 自己那次发信号 + safe_change_scene 的 _switching 双层兜住;
#  这里只负责"在树上才切"(原定时器 lambda 里那条 is_inside_tree() 早退的**意图**搬到这里)。
func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


# 结算页载荷(默认空)。三个子类各覆写一份 —— 模式差异只有这一点。
func _build_result_payload() -> Dictionary:
	return {}


# ── 对手副本访问器:两个模式**唯一的结构性差异**就收在这一个口上 ──
# 1v1 只有固定那一个副本(`_remote_replica`),大乱斗按 role 动态建(`_replicas`)。下面那些
# 消费快照/事件的函数原先因此各写两份,现在都改问这个口 —— ★ 子类**必须覆写**。
# 语义:`role` 是**对手**的 role(不是自己的);没有对应副本(未建/已移除)时返回 null,
# 调用方一律判空(不返回 null 会被下游 `.global_position` 打成崩溃)。
func _replica_for(_role: int) -> Node2D:
	return null   # 基类无副本;两个子类各自实现


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
		return
	# 对手被打:让它的副本闪一下,射手看得见"打中了"
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


# 服务器权威开火(即时光束武器,激光):对手端据此画光束视觉副本(不开物理子弹,
# 无 bullet_spawn 实体可跟)。原始 pts 在射手 canonical 系(可能隔整幅地图跨接缝)→
# 逐点锚到射手副本当前渲染位置(副本位置已由 player_replica 每帧归到本地玩家最近副本、
# 滞后 ~1 tick 无碍)。光束整条路径 ≤ bullet_range 远小于半图 → 逐点 anchor_to_nearest 会把
# 整条折线搬到可见副本、跨接缝连续。
# 只画对手那发:自己(射手)这发已由本地预测自画,再收服务器版会双光束。
func _on_beam_fired(data: Dictionary) -> void:
	if _world == null:
		return
	var shooter := int(data.get("shooter_role", 0))
	if shooter == PvpSession.role:
		return
	var replica := _replica_for(shooter)
	if replica == null or not is_instance_valid(replica):
		return   # 射手副本还没建(快照未到)→ 丢本发
	var raw: PackedVector2Array = data.get("pts", PackedVector2Array())
	if raw.is_empty():
		return
	var anchor: Vector2 = replica.global_position
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var pts := PackedVector2Array()
	for p in raw:
		pts.append(MazeGenerator.anchor_to_nearest(p, anchor, w, h))
	var color: Color = data.get("color", Color(0.1, 0.35, 1.0, 1.0))
	var half_width := float(data.get("half_width", 2.0))
	var lifetime := float(data.get("lifetime", 0.25))
	LaserVisual.spawn_muzzle_orb(_world, pts[0], color, half_width, lifetime)
	LaserVisual.spawn_beam(_world, pts, half_width, color, lifetime, int(data.get("style", 0)))


# ── 子类**必须覆写**的两口:昵称表 / 角色色相 ──
# 判据同 `_replica_for` —— 形状随"对手 1 个 vs N 个"而定,故实现留在子类;
# `_on_match_sync` 要用它们,故在这里声明(否则基类调用未声明的函数 = 编译不过)。
func _apply_peer_names(_names: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_names")


func _apply_peer_hues(_hues: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_hues")


# ── 「每个角色的颜色」那一段的**唯一分叉点**(基类钩子)──
# `_on_match_sync` 只调它一次,不再直接调 `_apply_peer_hues`。
#   · 默认(1v1 / 大乱斗):消费载荷里的 `hues`(每个 role 自选的色相)。
#   · 3v3(`team_game`)覆写:消费载荷里的 `teams`(队色),**刻意不调** `_apply_peer_hues`
#     —— 6 个人里认不出队友这个模式就没法玩,个人色相在 3v3 是无效输入。
# ★ 签名收**整个 payload** 而不是只收 `hues`:3v3 要读的是**同一份应答里的另一个键**;
#   只传 hues 会逼子类把 teams 先存进一个字段、再到钩子里取回来(多一条"上游写、下游读"的暗通道)。
# ★ 两个既有子类**都不覆写它**,且默认实现与改动前那两行逐字同构("非空才染色")
#   ⇒ 对它们是零影响(回归线:kh_l4/kh_l5/hud_declarative + 真链路探针)。
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var hues: Dictionary = payload.get("hues", {})
	if not hues.is_empty():
		_apply_peer_hues(hues)


func _on_match_sync(payload: Dictionary) -> void:
	# 本应答是**进场建态**还是**重连补态**?(见 `_resync_pull_pending`;读一次即清)
	var resync := _resync_pull_pending
	_resync_pull_pending = false
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	# 颜色那一段走**基类钩子**(默认 = 个人色相;3v3 覆写成队色,见 `_apply_peer_hues_or_team`)
	_apply_peer_hues_or_team(payload)
	var opts: Dictionary = payload.get("options", {})
	if not opts.is_empty():
		_apply_match_options(opts)
	# 出生点校正**只对进场那次做**:那时 `spawns[role]` 与 `PvpSession.spawn` 确实同源(都由
	# 服务器同一次摆位产生),不一致就是 bug —— 留痕 + 以 sync 为准。
	# ★ 重连补态那次**必然**不一致,而那不是 bug:1v1 每局换边(`match_round._start_next_round`
	#   翻 `_side_swap` → `role_spawns()` 在 player/player2 之间对调),而 `PvpSession.spawn` 只在
	#   进场写一次(`lobby_page` 配对时),此后无人刷新。按它硬拉 = 把玩家瞬移走,而服务器那具
	#   身体从掉线起就没动过 → C2 下一帧又把人拉回来,顺带刷一条假告警(告警的前提在这里不成立)
	#   淹掉探针日志。位置本来就归 C2 权威(服务器瞬移正是它要收敛的外部事件),故这条路
	#   **既不校正、也不告警、也不回写 `PvpSession.spawn`**(回写只会让下一次校正更歪)。
	var sp: Dictionary = payload.get("spawns", {})
	if not resync and sp.has(PvpSession.role):
		var want: Vector2i = sp[PvpSession.role]
		if want != PvpSession.spawn:
			push_warning("match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()
	# 地面武器**开局那批随本条拉取一并到达**(不走 weapon_spawned 推送 —— 推送会撞上
	# "客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失"那类事故,见 CoreNet 的注释)。
	# ★ **先清后灌**:载荷是全量,本地可能还留着掉线前的条目 → 不清会产生幽灵枪(见 _clear_ground_weapons)。
	var gw: Array = payload.get("ground_weapons", [])
	_clear_ground_weapons()
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)
	# ★★ 补态那一路:**先把本地世界还原成建局基线,再应用 `destroyed`**。顺序不可换。
	#   为什么必须还原:`destroyed` 表达的是「与建局基线**不同**的格」。客户端在宽限期内
	#   **错过一次换局**时,服务器那次 `_reset_world_and_clear_dynamics()` 已经把可破坏砖全都
	#   还原成了基线 —— 那些格于是**等于基线**、永不进载荷,而客户端本地还留着上一局拆出来的
	#   破洞(**幻影空洞**:服务器上那里是实心墙,客户端却少一堵/多一个能钻的缝)。
	#   客户端唯一的还原路径是新回合 COUNTDOWN 里的 `Level0.reset_destructibles()`
	#   (见 `pvp_game._on_round_state`),而重连回来时那一局可能**已经打到 PLAYING** →
	#   那条分支不触发 → 空洞要拖到下一个回合边界才自愈。
	#   ★ 为什么「先还原 + 再应用」就够了:两者合起来**恰好等于服务器的 grid** ——
	#     还原给出基线、`destroyed` 给出与基线的那份差异,而服务器那次换局正是"回基线 +
	#     本局重新拆"(换局后新拆的格仍在 `destroyed` 里)。**不上线任何新字节**。
	#   ★ 顺序反过来(先应用、后还原)会把刚补好的洞**又填回去**,症状与"根本没还原"逐字相同。
	#   ★ 只在补态这一路做(闸门就是上面那个读一次即清的 `resync`):进场那次世界刚从 pristine
	#     地图建出来,还原是多余动作(同款"进场那次本就是 no-op"的纪律见 `_clear_ground_weapons`)。
	#   ★ 非 COUNTDOWN 时刻调用安全:`reset_destructibles()` 只重铺瓦片层 + 整层重建碰撞,
	#     不碰玩家/子弹/地面武器(`WorldBuilder.build_sim` 只 free 自己那三个具名节点),
	#     代价是客户端一次墙层重绘 —— 与每个回合边界本来就要做的那次活一模一样。
	if resync and _level0 != null and _level0.has_method("reset_destructibles"):
		_level0.reset_destructibles()
	elif resync:
		# ★ 该还原而没还原 —— 留一条告警。`_level0` 是**由子类赋值**的共享状态字段(两个子类各自
		#   `_ready` 里写),漏赋值 / 赋错类型时上面那道闸**静默不成立**,还原就这么不发生,症状
		#   (幻影空洞拖到下一个回合边界)与"根本没写这段"逐字相同 —— 而"静默"正是这整批在消灭的形态。
		#   ★ 只告警,不改行为(告警不碰任何状态);闸门本身不动。
		var why := ("_level0 为 null(子类 _ready 漏赋值?)" if _level0 == null
				else "_level0 没有 reset_destructibles()(类型不对?)")
		push_warning("match_sync(补态): 世界未还原 —— %s;幻影空洞不会填回" % why)
	# 掉线窗口内被拆的墙(以及"换局还原"之后本局重新拆的那些):重连后补回。
	# (进场那次该字段为空 —— 刚建的世界与基线一致。)
	# ★ 复用 `_on_remote_tile_destroyed` 的静默形态,不另写一套清瓦片/清碰撞的逻辑。
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)


# ── 拾取诊断插桩(默认关)──────────────────────────────────────────────
# 开关:`-- --pickup-diag`。★ 必须写在 `--` 之后 —— 与 `--netstat` / `server_main` 的
#   `--worker` 同款口径;写在前面会被 Godot 丢掉、**静默失效**。
# 默认关 ⇒ 生产行为逐字不变(只多一次懒查开关的布尔判断)。
#
# 用来回答「地上的枪**看得见**、走过去却没有 F 提示」这一类问题 —— 那种症状只有两种成因:
#   ① 客户端压根没建出这把枪(`_spawn_pickup_node` 的早退是**静默 return**);
#   ② 建出来了,但它的 `canonical_pos`(提示判据读的那个值)与**画出来的位置**不在一处。
# 两个成因在画面上长得一模一样,只能靠数字分:下面逐条打"认不认、canonical/render/玩家各在哪、
# 三条闸门各是真是假"。判据是**玩家 400px 内的枪**每 30 物理帧打一行(默认关时不打)。
var _pickup_diag := false
var _pickup_diag_checked := false
var _pickup_diag_frame := 0


func _pickup_diag_on() -> bool:
	if not _pickup_diag_checked:
		_pickup_diag_checked = true
		_pickup_diag = OS.get_cmdline_user_args().has("--pickup-diag")
	return _pickup_diag


# ── 地面武器(2026-09-15):服务器权威,本端只渲染 + 等事件(不做客户端预测)──
var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}    # inst -> WeaponPickup
var _self_drop_until: Dictionary = {} # inst -> 解禁时刻(ms):**自己刚丢下**的那把,
                                      # 冷却期内不提示(与服务器 _live_self_drops 同口径;
                                      # 不排的话刚丢下的枪会显示 F 却捡不起来)

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


# 订阅服务器的两条地面武器事件。
# ★ **必须走 NetBus**,不是 NetBusExt —— 后者里有同名遗留的 beam_fired,挂错节点的
#   表现是**静默 no-op**(对手的枪凭空消失/永不再现,且不报错)。两个子类各自 _ready 里调一次。
func _subscribe_ground_weapons() -> void:
	NetBus.local_weapon_spawned.connect(_on_weapon_spawned)
	NetBus.local_weapon_removed.connect(_on_weapon_removed)


func _on_weapon_spawned(data: Dictionary) -> void:
	_spawn_pickup_node(data)


func _on_weapon_removed(data: Dictionary) -> void:
	_remove_pickup_node(int(data.get("inst", 0)))


func _spawn_pickup_node(data: Dictionary) -> void:
	# 诊断:早退是**静默**的 —— 先把"为什么没建"打出来(判据见 _pickup_diag 的注释)
	if _pickup_diag_on():
		print("[pkd] ← spawned inst=%s type=%s by_role=%s pos=%s vel=%s | world=%s local=%s 已有=%s" % [
				str(data.get("inst", -1)), str(data.get("type_id", -1)), str(data.get("by_role", -1)),
				str(data.get("pos", Vector2.ZERO)), str(data.get("vel", Vector2.ZERO)),
				"有" if _world != null else "空", "有" if _local != null else "空",
				"是" if _pickup_nodes.has(int(data.get("inst", 0))) else "否"])
	if _world == null:
		return
	var inst := int(data.get("inst", 0))
	if inst <= 0 or _pickup_nodes.has(inst):
		return
	var type_id := int(data.get("type_id", 1))
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, int(data.get("mag", 0)), data.get("vel", Vector2.ZERO))
	_world.add_child(node)
	# 权威位置与渲染位置分开(见 WeaponPickup 的字段注释):事件里的 pos 是 canonical。
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor((_local as Node2D).global_position if _local != null else Vector2.ZERO)
	node.sync_render_from_canonical()
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": int(data.get("mag", 0)),
			"pos": node.canonical_pos, "vel": data.get("vel", Vector2.ZERO)})
	_pickup_nodes[inst] = node
	# 服务器告诉我们"这把是谁刚丢下的":若是**自己**,冷却期内不给提示(与它自己的判定一致)。
	if int(data.get("by_role", -1)) == int(PvpSession.role):
		_self_drop_until[inst] = Time.get_ticks_msec() 				+ int(PlayerParams.weapon_pickup_self_delay * 1000.0)


# 清空本端的地面武器表与全部拾取物节点。给 `_on_match_sync` 的"先清后灌"用。
# ★ 为什么必须先清:`match_sync` 的 `ground_weapons` 是**全量**,而重连时本地表里还留着
#   掉线前的条目 —— 不清就直接 add,掉线期间**已被服务器移除**的那些会变成**永久幽灵枪**
#   (看着在、按 F 无效)。这正是阶段 2-A 要闭合的两类缺口之一。
#   进场那次本地本来是空的,清一遍是 no-op(所以统一走这条路,不为两种情况分叉)。
func _clear_ground_weapons() -> void:
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	ground_weapons.clear()
	_self_drop_until.clear()


func _remove_pickup_node(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)
	_self_drop_until.erase(inst)
	if _pickup_diag_on():
		print("[pkd] ← removed inst=%d" % inst)


# 每帧:① 把锚点推给所有地面武器(接缝另一侧的枪要画在身边那一份上);
#        ② 把落体的实际位置同步回本地表(提示的"最近一把"要跟着落点走);
#        ③ 更新 F 提示。
func _tick_ground_weapons() -> void:
	if _local == null:
		return
	var lp: Vector2 = (_local as Node2D).global_position
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		pk.set_anchor(lp)
		pk.sync_render_from_canonical()
		var e: Dictionary = ground_weapons.get_entry(int(inst))
		if not e.is_empty():
			e["pos"] = pk.canonical_pos
	_pickup_diag_frame += 1
	_update_pickup_prompt(lp)


# F 提示:贴到"**按 F 会捡到的那一把**"上方。★ 与服务器 `_try_server_pickup` 用同一个
# `nearest_within` + 同一个半径,否则会出现"提示了 A、服务器却捡了 B"。
# (客户端不预测,所以提示的语义是"服务器会同意的那一把"。)
# F 提示:**每把能捡的**各自一个(用户 2026-09-16「只要能捡起就会显示 F」)。
# 判据 = 在拾取半径内 + 该类型没被禁用。★ 客户端不知道服务器侧的"自己刚丢下"冷却
# (那条只有权威知道),所以刚丢下的那把会短暂显示提示但捡不起来 —— 已知的小缺口,
# 要消掉得让 `weapon_spawned` 带上 by_role。
func _update_pickup_prompt(lp: Vector2) -> void:
	var self_drops := _live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in _pickup_nodes:
		var n = _pickup_nodes.get(inst, null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		var can := false
		if _local != null and not _live_self_drops().has(int(inst)) 				and _local.weapons.is_slot_enabled(int(pk.type_id)):
			var d := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
		# 诊断:玩家附近的枪逐条打(判据见 _pickup_diag 的注释)。★ `can=否` 时把
		# **三条闸门各是真是假**分开打 —— 合成一个 false 就没法从日志看出是哪一条挡的。
		# ★ `canon` 与 `render` 两栏是这条插桩的**重点**:两者本应只差整数个地图宽/高;
		#   若 `render` 落在玩家身边而 `canon` 不是,就说明"画出来的枪"与"判据读的枪"分家了。
		if _pickup_diag_on() and _pickup_diag_frame % 30 == 0:
			var dd := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			if dd <= 400.0:
				print("[pkd]   inst=%d type=%d d=%.1f can=%s | 冷却=%s 启用=%s | canon=(%.0f,%.0f) render=(%.0f,%.0f) 玩家=(%.0f,%.0f) settled=%s" % [
						int(inst), int(pk.type_id), dd, "是" if can else "否",
						"是" if _live_self_drops().has(int(inst)) else "否",
						"是" if _local.weapons.is_slot_enabled(int(pk.type_id)) else "否",
						pk.canonical_pos.x, pk.canonical_pos.y,
						pk.global_position.x, pk.global_position.y, lp.x, lp.y,
						"是" if pk._settled else "否"])


# 仍在冷却期内的"自己刚丢下的" inst(与服务器 MatchGround._live_self_drops 同口径)。
func _live_self_drops() -> Array:
	var out: Array = []
	if _self_drop_until.is_empty():
		return out
	var now := Time.get_ticks_msec()
	for inst in _self_drop_until.keys():
		if int(_self_drop_until[inst]) > now:
			out.append(inst)
		else:
			_self_drop_until.erase(inst)
	return out


# ── 断线重连(2026-09-17;spec §3.4 **路径甲**:局内自动重连)──
# 「与 worker 的连接闪断」→ 自己连回去、重新认领 role、重置本地 C2 —— **不切场景、不重建世界**。
# (路径乙"回大厅后回局、重建场景"是 spec §3.5,归下一阶段,不在本文件。)
#
# ★ 触发点只有"服务器断开"一条(`NetBus.local_server_message`,由 `multiplayer.server_disconnected`
#   驱动)。对局场景此前**没人订阅**它 —— 那条信号的消费者只有 `lobby_page`,所以服务器一断客户端
#   毫无反应:快照停更、输入自停(`_physics_process` 的 `can_send_to_server()` 转 false),玩家卡在
#   一个静止的世界里只能按 ESC 自救。这正是 spec §1.3 记的既有缺陷。
# ★★ 两条时间尺度,**别合并**:
#   · `RECONNECT_RETRY_MS`(2s)= **定时器节拍** —— 多久看一眼(等应答 / 两次尝试之间);
#   · `RECONNECT_ATTEMPT_TIMEOUT_MS`(5s)= **一次连接尝试自己的寿命** —— 一次握手最多活多久。
#   合并成"每 2 秒 `NetBus.stop()` + 重连一次"会在**高 RTT 链路**上反复掐掉正在握手的尝试
#   (比不掐更糟);而**只**看节拍、不掐尝试,就是 2026-09-17 修掉的那个缺陷(见 `_retry_connect`)。
const RECONNECT_RETRY_MS := 2000
# 一次尝试的寿命。取值依据:一次成功握手约 2~3×RTT,5s 覆盖到 ~1.6s 的 RTT(再差的链路本就没法打);
# 而 ENet 自己的连接超时实测 **~31.8s**(连一个没人监听的端口)—— 不主动掐的话,一次尝试就能吃掉
# 宽限期(`GraceWindow.DEFAULT_SECONDS`)预算的一半上下,且那整段期间**一次 tick 都没有**。
const RECONNECT_ATTEMPT_TIMEOUT_MS := 5000
var _reconnecting := false
var _reconnect_started_ms := 0   # ★ **真实断开**时刻(不是"关菜单"时刻,见 _begin_reconnect)
var _reclaim_sent := false   # ★ **本条连接上**是否已发过 reclaim(判据见 _on_reconnect_retry_tick)
var _pending_disconnect := false   # 断线时菜单开着 → 记账,关菜单再来(见 _recheck_disconnect)
var _attempt_started_ms := 0   # 当前这次连接尝试的起飞时刻;**0 = 没有尝试在飞**
var _retry_timer: SceneTreeTimer = null   # 单一定时器(判据见 _schedule_reconnect_retry)
# ★ 下一条 `match_sync` 应答属于**重连补态**(而非进场建态)。两口共用同一条信号(重连不重建
#   场景 → `pvp_game`/`royale_game._ready` 里那个订阅还在),而 `_on_match_sync` 里的出生点校正
#   对两种口径的答案**相反**(见那一支的注释),故必须让应答自己知道是哪一次拉的。
#   取用点:`_on_match_sync` 首行(读一次、当场清掉);置位点:`_on_resumed` 发送前那一行。
# ★ 2026-09-19(3v3)第二个置位点:`team_game._on_round_state` 的「新一轮 COUNTDOWN」那一拉。
#   那里问的是**同一个问题**("这条应答不是进场建态吗?") —— 换边后 `spawns` 是**新一侧**,
#   而 `PvpSession.spawn` 手里是旧一侧,两者**必然**不一致(与重连那条同款),照进场口径
#   硬拉 = 每局边界刷一条假告警 + 一次多余瞬移。故它复用同一个闸,不另立标志。
var _resync_pull_pending := false


# 两个子类各自 `_ready` 里调一次(与 `_subscribe_ground_weapons()` 并列)。
func _subscribe_reconnect() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	# ★ worker 在宽限期内接受 reclaim 后会**重发一条 match_start**(载荷与首次开局同源)。
	#   **实读确认**:对局里 `local_match_start` 此前**零订阅者** —— 它唯一的消费者是
	#   `lobby_page._on_match_start`(`matchmaking`/`royale_lobby` 的公共基类),而那个页面在对局
	#   场景里**不在树上** → 这条信号到对局里是**静默 no-op**。所以"重连成功"的收尾必须在这里接
	#   (`_on_match_start_event`)—— 不能指望既有入口。
	NetBus.local_match_start.connect(_on_match_start_event)


func _on_server_message(msg: String) -> void:
	if _match_ended or _reconnecting:
		return
	# 服务器文本播报也走这条信号,但对局期间服务器只发「对局开始」/「大乱斗开始」(已核);
	# 大厅那些「房间已满」之类不会到对局场景。
	if msg.contains("断开") or msg.contains("断开连接"):
		_pending_disconnect = true
		_begin_reconnect()


# 菜单关掉时补一次:真掉线正好落在"菜单开着"那段窗口里时,上面那次 `_begin_reconnect` 会被挡下
# (见它的守卫),账记在 `_pending_disconnect` 上,关菜单这一刻补上。不补的话玩家会留在一个
# 快照停更的静止世界里 —— 正是本功能要消掉的那个状态。
# ★ 它**不是**"按 ESC 回主菜单"那一路(原注释这么写,已被实测推翻,见 `_begin_reconnect` 的守卫)。
#   它服务的是"菜单开着时真掉线"这一档。
func _recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


# 局内自动重连:不切场景、不重建世界 —— 场景与节点原样保留,只把连接接回去。
# ★★ "不重建场景"**不等于**"世界没变":掉线那 `GraceWindow.DEFAULT_SECONDS` 秒里服务器照跑 ——
#   对面把墙拆了、地上的枪被捡走/丢弃/换局重铺。所以这条路径**同样要**拉一次 `match_sync`,
#   把破坏态与地面武器补回来
#   (见 `_on_resumed` 末尾那一拉;`destroyed` 不是路径乙专属)。★ 别把"世界还在原地"读成
#   "没什么要补的" —— 那正是删掉那两行、让幻影墙/幽灵枪悄悄回来的那个想法(漏了不报错)。
func _begin_reconnect() -> void:
	# ★ MATCH_OVER / 对手离开那两条延时回菜单的路子会先 `NetBus.stop()`,而它断开的是我们自己。
	if _match_ended:
		return
	# ★ 宽限期预算的**起算点 = 真实断开这一刻**,故记在这里、且在那道菜单守卫**之前** ——
	#   菜单开着的闪断若等"关菜单"才起算,等于凭空多拿一段预算(spec 的宽限期按**服务器**的
	#   掉线检测起算,客户端这边晚算的那几秒会让最后几次 reclaim 打在"已被移出"上)。
	#   ★ 只在**没人记过**时才记:关菜单时 `_recheck_disconnect()` 再来一次,预算要接着走,不重置。
	if _reconnect_started_ms == 0:
		_reconnect_started_ms = Time.get_ticks_msec()
	# ★ 菜单开着**先不动,但不是放弃**(放弃会把真掉线也一起漏掉)。★★ 2026-09-17 订正本守卫的
	#   理由:原先写的是"按 ESC →「回到主菜单」也走 `NetBus.stop()`,此刻接着重连会在回主菜单的
	#   路上把连接接回 worker" —— **那个前提不成立**:`NetBus.stop()` 把 `multiplayer_peer` 置空,
	#   引擎在 `set_multiplayer_peer` 里先 `clear()`、`last_connection_status` 当场复位成
	#   DISCONNECTED,CONNECTED→DISCONNECTED 那一跃**从未被观测到** → `server_disconnected`
	#   (本文件 `_on_server_message` 的唯一上游)**根本不会发**;而且 `PauseMenu.go_menu()` 走的是
	#   直接 `NetBus.stop()`,连 `toggled`(→ `_recheck_disconnect`)都不经过。故"ESC 会引发重连"
	#   这条路径不存在。
	#   ★ 守卫**仍然保留**,理由换成成立的这一条:**菜单开着时真掉线是可能的**(服务器踢人 /
	#   网络断),而那一刻的重连要**推迟到关菜单**再发 —— 玩家下一秒可能就点「回到主菜单」,
	#   先把连接接回 worker 再走人,就会留下"人已走、role 仍被占"的幽灵(对手那边卡死、无报错)。
	#   推迟的账记在 `_pending_disconnect` 上,由 `_recheck_disconnect()` 在关菜单时补。
	#   (另一侧:`_exit_tree` 兜"重连已经在飞、玩家又按 ESC 走了"。)
	if _menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")   # 原版 worker / 老大厅 → 优雅降级
		return
	_reconnecting = true
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


# 连一轮(先把上一轮拆干净)。★ 与 `lobby_page` 转连 worker 那一处同款:
# `start_client` 的地址/端口取自 `PvpSession`(大厅填好的,不重新走大厅)。
func _retry_connect() -> void:
	if not _reconnecting:
		return
	NetBus.stop()
	_reclaim_sent = false   # 新连接 = 新的一次 reclaim 额度(旧连接上那次的成败已无意义)
	_attempt_started_ms = 0   # 上一轮(若有)就此作废
	# ★ 上一轮那两条**一次性结局回调若还没触发,仍挂在 MultiplayerAPI 上**(信号回调挂在对象上,
	#   不随 `multiplayer_peer` 换掉,也不随 `NetBus.stop()` 清),不清的话新连接握手成功那一次
	#   emit 会把它们**一起**叫起来 —— `_try_reclaim` 会被叫两次(见它的守卫)、
	#   `_on_reconnect_failed` 的旧回调还可能把**新一轮**的尝试记账清零。故每次重连先摘干净。
	if multiplayer.connected_to_server.is_connected(_try_reclaim):
		multiplayer.connected_to_server.disconnect(_try_reclaim)
	if multiplayer.connection_failed.is_connected(_on_reconnect_failed):
		multiplayer.connection_failed.disconnect(_on_reconnect_failed)
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		_schedule_reconnect_retry()
		return
	# 尝试已起飞:记下起飞时刻(掐它的唯一判据),并挂上两条一次性结局信号。
	_attempt_started_ms = Time.get_ticks_msec()
	multiplayer.connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)
	# ★★ 成功这条**也要挂定时器**(2026-09-17 修:原先只有 `err != OK` 那条挂)。不挂的话,
	#   "一次连接尝试正在飞"的整段期间**一次 tick 都没有** —— 宽限期判据从不被求值,而 ENet
	#   自己的连接超时实测 **~31.8s**(连一个没人监听的端口)→ 最坏情形是**卡在冻结世界 ~32 秒**
	#   才回主菜单(本机实测:尝试@0.15s → `connection_failed`@31.81s → 由失败那一刻才挂上的
	#   tick 在 ~33.8s 判超时)。★ 这里的病**不是**"宽限期太短"(当年它恰好是 30s),而是那一段
	#   期间判据**一次都没被求值** —— 所以时长改成多少,这条修复的必要性都不变。
	#   挂上之后这一路 tick 只多做一件事:到 `RECONNECT_ATTEMPT_TIMEOUT_MS` 就掐掉重开一次
	#   (见 `_on_reconnect_retry_tick`)。
	_schedule_reconnect_retry()


func _on_reconnect_failed() -> void:
	_attempt_started_ms = 0   # 这次尝试已有结局(失败)→ 下一拍重开,不必再等尝试超时
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return   # 期间已收场(超时/已离开) → 不发
	# ★★ **本条连接上只发一次**(本功能最要害的不变量):worker 接受第一次时就 `_grace.leave(role)`
	#   了,同一条连接上再发一次,进 `_on_reclaim` 的判据②必不成立 → 它**踢连接**。
	#   这一行是**兜底**:正常路径由 `_retry_connect` 每次重连把旧的一次性回调摘干净来保证
	#   (见那里的注释),但"只发一次"这件事值得在发的地方再写死一次。
	if _reclaim_sent:
		return
	# 握手落地 = 这次尝试**有结局了** → 不再受"尝试超时"管辖,只剩"等应答"这一档。
	_attempt_started_ms = 0
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)
	# ★ 等 worker 回的 match_start(它带 spawn/map_path)。等到了才算成功,见 _on_resumed。
	_schedule_reconnect_retry()


# 重试节拍(单一定时器;每一拍自己判"再连一轮"还是"只等应答")。
# ★ **一个时刻只能有一个定时器在飞**:OK 路径那条"尝试超时"会与 reclaim 后那条"等应答"重叠
#   (`connected_to_server` 一到,`_try_reclaim` 又挂一个),不拦的话每一拍会跑两遍。
#   已有的没到点就直接返回 —— 链条不会断:`_on_reconnect_retry_tick` 除收场那两条外**每条分支
#   都会再挂一次**,所以任何时候都至少有一个在飞。
func _schedule_reconnect_retry() -> void:
	if not _reconnecting:
		return
	if _retry_timer != null and _retry_timer.time_left > 0.0:
		return
	_retry_timer = get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0)
	_retry_timer.timeout.connect(_on_reconnect_retry_tick)


func _on_reconnect_retry_tick() -> void:
	if not _reconnecting:
		return
	# ★★ 宽限期判据是**第一条**,且与"这次尝试走到哪一步"**无关** —— 两条路径(`err != OK` 与 OK)
	#   现在都挂了定时器,所以哪怕握手一直不落地(一次 reclaim 都没发出去),整整一个
	#   `GraceWindow.DEFAULT_SECONDS` 也一定到点。
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	# ★★ **同一个 role 只许发一次 reclaim**(本功能最易写错、且症状最怪的一处):
	#   worker 接受第一次时就 `_grace.leave(role)` 了,第二次进 `_on_reclaim` 的判据②
	#   ("该 role 必须在宽限期里")必不成立 → 它**踢连接**。表现是"刚重连上几秒又断",
	#   看着像网络抖动,实则是自己把自己踢了,而且因为 token 是对的,查 token 查不出问题。
	#   判据:这条连接**还活着**、且**已发过** reclaim → 该做的是**等**它的 match_start
	#   (可靠的定向应答,连着就一定到),而不是重连一轮再发一次。
	#   真发不出去(连接没了 / 被服务器踢了)`can_send_to_server()` 即为 false,自然走到下面重连。
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	# ★ 一次握手最多活 `RECONNECT_ATTEMPT_TIMEOUT_MS`(还没起飞的不受此限:0 = 无尝试在飞)。
	#   ★ **这里绝不能用 `RECONNECT_RETRY_MS`** —— 每 2 秒 `NetBus.stop()` + 重连会在高 RTT 链路上
	#     反复掐掉正在握手的尝试,比不掐更糟;那个值只管"多久看一眼"。
	#   到点仍未落地 = 这次多半不会落地了(ENet 自己的超时 ~31.8s,是它的 6 倍多)→ 掐掉重开,
	#   让宽限期预算里能放下十来次尝试,而不是宁可干等一两次。
	var attempt_age := Time.get_ticks_msec() - _attempt_started_ms
	if _attempt_started_ms > 0 and attempt_age < RECONNECT_ATTEMPT_TIMEOUT_MS:
		_schedule_reconnect_retry()
		return
	_retry_connect()


# worker 接受 reclaim 后重发的那条 match_start 到达 → 重连成功。
func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	# 非重连态收到它 = 首次进场那一份(由 `lobby_page` 消费;本场景那时还没建出来)或异常来源,
	# 两种都**不动本地世界** —— 本路径不重建场景,故 role/spawn/map_path 一个都不回写
	# (`PvpSession.spawn` 在大乱斗里是"动态复活点"语义,回写只会让下一次 `_correct_local_spawn`
	#  把玩家瞬移走)。
	if not _reconnecting:
		return
	_on_resumed()


# 重置本地 C2 状态(spec §3.4 的 ★:不重置会把断线前的记录当"未确认输入"重放)。
func _on_resumed() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	# ★ 必须重置:worker 在 reclaim 时把 `_ack_seq[role]` 归 0 重协商锚点,而客户端这边的 `_acked`
	#   还停在断线前那个数 —— 不重置的话新快照的 ack 一律 `<= _acked`,`on_authoritative` 全数丢弃
	#   (C2 静默失效,要等 seq 重新爬过断线前那个数才恢复),同时环里那些断线前的记录会被当成
	#   未确认输入重放,与服务器的新锚点错位。
	_input_seq = 0
	_have_prev_seq = false
	_prev_sent_seq = -1
	# ★ 新实例必须**重新 bind + 设 map_px**,照抄两个子类 `_ready` 里那三行。漏了**都不报错**:
	#   没 bind → `_handle_ack` 里 `_p == null` 直接 `_trim` 返回,分歧永不修复(静默失去 C2);
	#   没设 map_px → 跨接缝那一帧按裸距离比,白跑一次回滚(同 `_ready` 里那条注释)。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# ★ 路径甲(局内自动重连)**原来不需要 `match_sync`** —— 场景没重建、本地世界还在。
	#   现在需要了:**世界在掉线那 `GraceWindow.DEFAULT_SECONDS` 秒里变过**。这一拉把两类丢掉的
	#   可靠事件一次补回:
	#     · destroyed   —— 被拆的墙(不补 → 幻影墙 → 预测分歧)
	#     · ground_weapons —— 掉落/被捡走的枪(不补 → 幽灵枪 / 看不见的枪)
	#   ★ 顺序:上面已经把 C2 重置完了(新 rollback / _input_seq=0),**再**拉。
	#     (原写"反过来的话应答里的出生点校正会与重置打架" —— 那条校正在补态这一路上**已不再
	#      执行**(见 `_resync_pull_pending`),故它不再是硬约束;保持"最后拉"的形状不变。)
	#   ★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了**不报错**,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		# ★ 先置位再发:这条应答是**补态**口径,`_on_match_sync` 据此跳过出生点校正
		#   (它按 `spawns` 校正/告警的前提在这里不成立,见那一支的注释)。
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")
	print("[pvp] 重连成功")


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉在飞的重连。
# ★ 必须有:`_reconnecting` 期间玩家仍可按 ESC 离场,不停的话重连循环会**从主菜单**继续跑,
#   连上还 reclaim 成功 → worker 认为这个 role 有人管(正是 `_begin_reconnect` 那道守卫要防的
#   同一个后果,只是入口在另一侧:那边防"开始时",这边防"开始后")。
# ★ 只在**真在重连**时断连:本函数跑在新场景 `_ready` **之后**(`safe_change_scene` 先 add 新场景
#   再摘旧场景),无条件 `NetBus.stop()` 会把新场景刚建起来的连接干掉。
func _exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()

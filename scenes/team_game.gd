extends PvpMatchClient
# 3v3 团队对局客户端(第三个对局场景,与 `pvp_game` / `royale_game` **同基类**)。
# Level0(pvp_mode) 世界 + 本地玩家(C2 客户端预测) + **5 个**远端副本(懒建,同大乱斗那套)
# + 后处理 + 输入上报 + 快照消费 + `TeamHud`(记分条按**队号**,不是 role)。
#
# 与另外两个客户端的**全部**差异只有三处:
#   ① 副本是 5 个 —— 结构上与大乱斗**逐字同款**(`_replicas` 按快照 role 懒建),故那一侧不重写;
#   ② **队色覆盖个人色相** —— 本体染色(**含自己那具**) / 头顶 ID / 小地图点位一律问
#      `_team_color(role)`;`peer_hues` 在本模式是**无效输入**(基类钩子 `_apply_peer_hues_or_team`
#      被覆写成只消费 `teams`,连 `_apply_peer_hues` 都不进 —— 不是"染完再盖",是根本不走那条路);
#      ★ 2026-09-21 用户裁定:「3v3 青队玩家还是看见自己是蓝色的」⇒ **自己那具也改走队色**,
#        个人色相在本模式**整体停用**(此前它唯一的落点就是自己那具)。见 `_refresh_team_colors`。
#   ③ **队友不互挡**的**客户端一半**(服务端那一半在 `TeamHost._apply_team_layers`,契约数值见
#      `_apply_team_collision` 的注释)。★ 这条漏了的后果与"幽灵碰撞体缺失"同款:C2 每帧回滚。
#
# ★ 队伍表**只从 `match_sync` 进来**(与昵称/色相/生效选项同一条投递路径)。不要从 `roles` 推导:
#   role 号由大厅「最小空闲号」分配、有人退出后会留空洞(3 人房里中间那位退掉 → 房里是 {1,3})。


var _last_snap_tick := 0
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色)
# ★ `_level0`(世界/Level0)已上提到基类(子类 `_ready` 里赋值;重连补态那一路要用它还原可破坏砖)。
var _hud: TeamHud = null
var _pause_menu: PauseMenu = null   # ESC 菜单(MATCH_OVER 后销毁以失效,见 _on_round_state)

# ── 队伍表(role -> 队号 1/2;由 `match_sync` 下发,★ 不得从 roles 推导)──
var _teams: Dictionary = {}

# ── 头上 ID / 血条(按 role 管理,同大乱斗)──
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
var _id_labels: Dictionary = {}    # role(int) -> WorldLabel(含自己)
var _hp_bars: Dictionary = {}      # role(int) -> EnemyHpBar(仅他人,设置开启时)
var _names: Dictionary = {}        # role(int) -> 昵称(match_sync 下发)


func _ready() -> void:
	CombatComponent.pvp_arena = true
	MazeGenerator.set_map_file(PvpSession.map_path)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 与其它玩家(层 2)物理碰撞 —— **这只是队伍表到达之前的临时态**:
	# 服务器侧 `TeamHost._apply_team_layers` 给每个玩家按队配层,客户端在 `_apply_teams` 里
	# 用 `_apply_team_collision()` 跟上同一条契约。两者不同步 = 每帧分歧回滚。
	# 时间窗只有开局倒计时那几秒(玩家被 `set_controls_locked` 冻着),故先用"全员互挡"兜住。
	# ★ 不要因为下面有 `_apply_team_collision()` 就把这一行删掉:队伍表到达前它**是唯一**的碰撞来源。
	local.collision_mask |= 2
	_local = local
	# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从本人包的 ack_seq/c2 喂入。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
	# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 快照/事件消费(与另两个客户端同一张清单)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBusExt.local_sub_destroyed.connect(_on_remote_sub_destroyed)
	_setup_beta_time_hud()   # Beta 时间玩法:怀表镜像(普通局内部自短路)
	NetBus.local_round_state.connect(_on_round_state)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	_subscribe_ground_weapons()   # 地面武器事件(开局那批走 match_sync,见 _on_match_sync)
	_subscribe_reconnect()        # 断线重连:服务器断开检测 + reclaim 成功后那条 match_start
	# 小地图(多目标 + **队色**):三个提供器**同序**一一对应(错位 = 队友点画成敌人色,不报错只误导人)。
	# ★ 后两个用**具名方法**而不是内联 lambda —— 三个 lambda 中间那个要以 `return arr,` 结尾,
	#   那是本仓没写过的形状(计划里标注过的坑);具名方法直接绕开,且两个方法挨着写、同序可核。
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"))
		add_child(minimap)
	# HUD(记分条按队号)+ Esc 菜单
	# ★ 声明式场景实例化,不能 `TeamHud.new()` —— 那个建出来的 CanvasLayer 没有子节点,
	#   HUD 的 @onready 全是 null、_ready 解引用必崩(B11;守卫 `tests/hud_declarative_probe`)。
	_hud = preload("res://ui/team_hud.tscn").instantiate() as TeamHud
	add_child(_hud)
	_pause_menu = PauseMenu.new(true)
	# 本地输入锁必须宿主接线:PvP 不暂停树,不锁就是"菜单开着还能边跑边开枪"。
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 PvpMatchClient._begin_reconnect)
	add_child(_pause_menu)
	# ★ 自己那具的染色**不在这里做**,等队伍表(见 `_refresh_team_colors`)—— 2026-09-21 用户
	#   裁定:**3v3 下自己是队色**,与"看别人"同一份来源(个人色相在本模式**整体停用**)。
	#   用户原话:「3v3 青队玩家还是看见自己是蓝色的」—— 根因就是这一行此前传的是
	#   `Settings.pvp_color_hue`,而它的默认值 0 = **不改色** ⇒ 身体恒为本体蓝
	#   (= 队 1 的颜色,青队玩家因此看见自己与队 1 同色)。
	#   队伍表随下面那一拉 `match_sync` 到达 → `_apply_teams` → `_refresh_team_colors()`。
	#   在那之前身体保持**未染色**(本体蓝,与另两个模式刚进场时逐字同款)。
	#   ★ 别在这里补一句"表到达前先用 pvp_color_hue 兜一下":那是给**同一个语义**开第二条
	#     来源(且会在倒计时里闪一次颜色,玩家看得见),而这张表一个 RTT 就到。
	#   ★ 表真缺了(`_apply_peer_hues_or_team` 的 push_warning 那一支)则整局保持本体蓝 ——
	#     那条路已有响亮的告警,不是静默。
	# ★ 进场**主动拉**一次(昵称/队伍/生效选项/出生点/地面武器/destroyed)。本场景此刻已建好并
	#   订阅齐了才开口要,故不存在"推给一个正在切场景的客户端"那个竞态(B2 的根因)。晚到也无所谓。
	# ★ 判活再发(全仓纪律,与另两个对局场景那两处逐字同款):定向可靠包,连接可能已经不可用。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入 3v3:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# ── 队伍表:唯一入口 = 基类钩子 `_apply_peer_hues_or_team`(由 `_on_match_sync` 调)──
# ★ 为什么落成**钩子覆写**而不是自己覆写整个 `_on_match_sync`:基类那份把"名字/颜色/选项/
#   出生点校正/地面武器先清后灌/destroyed 补态"六件事写在一起,3v3 要的差异只有"颜色那一段
#   换个来源"。整段抄一遍 = 把"先清后灌""静默补态"两条纪律**复制成两份**,将来只改一处。
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var teams: Dictionary = payload.get("teams", {})
	if teams.is_empty():
		# 3v3 worker 的 `team_map()` 恒非空(队伍表由 `--teams` 显式传入),故这里到不了。
		# 真到这儿的话后果是 `_my_team` 恒 0 → **赢的局会被 HUD 报成输的**(见 `_apply_teams` 的注释),
		# 故留一条痕而不是静默。
		push_warning("match_sync: 3v3 载荷里没有 teams(队伍表没到 → HUD 判不出我方胜负)")
		return
	_apply_teams(teams)


# 应用函数(不是信号回调)。★ 幂等:每次 `match_sync`(进场 / 换局重拉 / 重连补态)都会走一遍。
func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	if _hud != null and is_instance_valid(_hud):
		# ★★ 这一行漏了**不报错**,后果是**赢的局报成输的**:`_my_team` 恒 0 ⇒
		#   `TeamHud` 的 `mwinner == _my_team and _my_team != 0` 恒假 ⇒ 「本局胜利!」/「胜利!」
		#   **两条文案一次都不会出现**,一律落进 else 念「本局落败」/「失败」。
		#   (★ 平局那一支**不受影响**:它走的是 `else`,`_my_team` 取什么值都念「平 局」——
		#    别把这条契约写成"平局分支不可达"。)队号**只能**从队伍表读 —— 不是 role。
		_hud.set_my_team(_team_of_role(PvpSession.role))
	_refresh_team_colors()
	_apply_team_collision()


func _team_of_role(role: int) -> int:
	return int(_teams.get(role, 0))


# 反查某个节点(自己 / 某个副本)是哪个 role。查不到返回 0(= 与 `_team_of_role` 的"表外"同码)。
func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	if n == _local:
		return int(PvpSession.role)
	for role in _replicas:
		if _replicas[role] == n:
			return int(role)
	return 0


# 覆写基类:3v3 里**队友副本不挡自己的子弹**(规则 12「子弹穿透队友」)。
# ★ 基类默认"除射手外谁都能挡"对 1v1/大乱斗是对的;不覆写的话,队友副本会把子弹吃掉 ——
#   而服务器那边是穿过去的 ⇒ 客户端凭空少一颗子弹,且**一条报错都没有**。
func _bullet_hits_entity(b: BulletBase, ent: Node2D) -> bool:
	var sr := _role_of_node(b.shooter)
	var er := _role_of_node(ent)
	if sr == 0 or er == 0:
		return true        # 认不出队:退回基类语义(能挡),不静默改成"全穿透"
	return _team_of_role(sr) != _team_of_role(er)


# 队色统一收在**这里**:自己的染色、副本染色、头顶 ID、小地图点位都问它。
# ★ 3v3 下**个人色相不生效**(`peer_hues` 被队色覆盖)—— 这是规则不是审美:
#   6 个人里认不出队友,这个模式就没法玩。`_apply_peer_hues_or_team` 里**不要**再调 `_apply_peer_hues`。
func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)   # 无队伍(理论上到不了)→ 中性亮白


# 把队色刷到**身体**上。★ 机制收在 `PvpMatchClient._apply_tint` 的第三参里(modulate **比值**,
# 不是直接乘队色 —— 那样蓝身体乘橙会变灰紫),这里的第三参就是"染成这个颜色"。
# ★★ **自己那具与副本走逐字同一条路**(2026-09-21 用户裁定):队色的**单一来源**只有
#    `_team_color(_team_of_role(role))` 这一处 —— 此前自己那具传的是 `Settings.pvp_color_hue`
#    (自选色相),于是"青队玩家看见自己是蓝色"(默认色相 0 = 不改色 ⇒ 恒为本体蓝 = 队 1 色)。
#    个人色相在 3v3 因此**整体停用**(它在本模式再无任何落点;大乱斗那侧不受影响)。
# ★ 队号 0(队伍表还没到)时**不染自己**:`_team_color(0)` 返回中性亮白,把它糊在自己身上
#   比"保持本体蓝"更糟。表一个 RTT 就到,这一支只在表缺失时才走得到(那里另有 push_warning)。
func _refresh_team_colors() -> void:
	if _local != null and _team_of_role(PvpSession.role) != 0:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(PvpSession.role))
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), 0.0,
					_team_color(role))
	_refresh_names()


# 某个 role 的副本**幽灵体**该在的层(契约表见 `_apply_team_collision`)。
# ★ 队号 0(不在队伍表里)走 else = 层 16 —— 与 brief 给的那句逐字一致,A 册服务端侧对未知队号
#   是"什么都不配"(保持层 2)+ `push_error`;生产路径上不该出现队号 0,这里**不写特例**(登记在报告)。
func _ghost_layer_of(role: int) -> int:
	return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER


# ── 队友不互挡:**客户端**那一半(服务端那一半在 `TeamHost._apply_team_layers`)──
# 契约(A 册定死,两边逐值对齐):
#   1 队玩家  layer = 2                          mask = 21(= 地形 1 | 敌人层 4 | **队 B 层 16**)
#   2 队玩家  layer = 16(`TeamHost.TEAM_ENEMY_LAYER`) mask = 7(= 地形 1 | 敌人层 4 | **玩家层 2**)
#   副本幽灵体 mask 恒 0,**layer 按它代表那名玩家的队**。
# ★ 为什么必须"分队位"而不是改掩码:Godot 的碰撞**按节点**配,没有"按对"的开关。
# ★ 为什么 layer/mask 两边必须逐值相同:服务器是权威模拟,客户端是 C2 预测 —— 掩码不同
#   = 同一帧两边的可走空间不同 = 每帧分歧、每帧回滚(C2 的无限回滚循环,不是调参能缓解的)。
# ★ 用常量不用字面量 16:层位是全局资源(第 5 位在本批之前无人占用),将来可能挪。
func _apply_team_collision() -> void:
	if _local == null:
		return
	var my_team := _team_of_role(PvpSession.role)
	if my_team == 0:
		return   # 队伍表还没到 → 保持 `_ready` 里那句 `|= 2` 的临时态
	if my_team == 1:
		_local.collision_layer = 2
		_local.collision_mask = (_local.collision_mask & ~2) | TeamHost.TEAM_ENEMY_LAYER
	else:
		_local.collision_layer = TeamHost.TEAM_ENEMY_LAYER
		_local.collision_mask |= 2
	for role in _replicas:
		var r = _replicas[role]
		if r != null and is_instance_valid(r) and r.has_method("set_ghost_layer"):
			# ★ 副本的幽灵体按**它代表的那名玩家**的队设:队友副本不挡我、敌人副本挡我
			r.set_ghost_layer(_ghost_layer_of(int(role)))


# 小地图:两个提供器的**共同遍历** —— 一次过滤、一份顺序来源。
# ★ 为什么必须共用而不是各写一份 `for`:`ui/minimap.gd` 是**按下标**对应的
#   (`_other_dots[i].color = cols[i]`),两个数组**错位一格**就是"队友点画成敌人色" ——
#   不报错、只误导人。而错位最容易发生在"某一个副本已 `queue_free`、尚未从 `_replicas` 抹掉"
#   那个窗口里(`_remove_replica` 与 `is_instance_valid` 之间),所以**过滤条件只此一份**。
# ★ 顺序:`_replicas` 是 Dictionary(GDScript 保插入序),两次调用之间没有任何写入
#   (Minimap 的 `_process` 连着调这两个提供器,中间不 await)⇒ 两边逐项同序。
func _minimap_entries() -> Array:
	var arr: Array = []
	for role in _replicas:
		var r = _replicas[role]
		if is_instance_valid(r):
			arr.append([int(role), (r as Node2D).global_position])
	return arr


func _minimap_others() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(e[1])
	return arr


# 与 `_minimap_others()` 一一对应的颜色:队友点画队色,敌人点画**对方队色**
# (3v3 下"这是谁"比"是不是敌人"更需要一眼看出;点的大小/位置仍照旧)。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(_team_color(int(e[0])))
	return arr


# 进场拉取的应答。★ 本文件**不覆写** `_on_match_sync`(六件事全在基类),只覆写颜色那一段的钩子。


func _on_snapshot_world(snap: Dictionary) -> void:
	if _local == null:
		return
	var snap_tick := int(snap.get("tick", 0))
	if snap_tick < _last_snap_tick:
		return
	_last_snap_tick = snap_tick
	var players_snap: Dictionary = snap["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role != PvpSession.role:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				r.set_meta("haste", bool(data.get("haste", false)))   # Beta:他人加速视效
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
		# ★ 自己那一份**刻意不消费**:C2 下本地玩家由引擎自步进,权威整态走**本人包**
		#   (见 `_on_snapshot_own`)。把世界包里自己那份写进玩家 = 每帧强写 = 橡皮筋。
	# 清理已离开玩家(掉线者从快照消失):副本/头顶ID/血条一并移除
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			_remove_replica(int(role_str))


# 懒建远端副本(按快照里出现的 role)—— 5 名对手数量固定但 role 号可能不连续
# (大厅按最小空闲号分配、有人退出后留空洞),故与另两个模式同款:快照里出现才建。
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "ReplicaP%d" % role
	_world.add_child(replica)
	_replicas[role] = replica
	_ensure_id_label(role)
	# ★ 队色与幽灵体层**必须在这里也补一次**:副本是懒建的,而队伍表早在 `match_sync` 就到了 ——
	#   `_apply_teams()` 那一刻 `_replicas` 还是空的,只在那时刷的话,晚建的副本会停在
	#   无人色(默认蓝)且幽灵体恒在层 2(= 队友也挡我)⇒ 每帧回滚。两处都不报错。
	_apply_tint(replica.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(role))
	if replica.has_method("set_ghost_layer"):
		replica.set_ghost_layer(_ghost_layer_of(role))
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar
	_refresh_names()


# 移除已离开玩家的视觉件:副本/头顶ID/血条
func _remove_replica(role: int) -> void:
	if _replicas.has(role):
		var r: Node2D = _replicas[role]
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
	_refresh_names()


# 击杀播报:我击杀对手 → 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)。
# ★ 载荷仍是 **role 粒度**(射手 = 归因得到,0 = 无归因)—— 协议不为团队改字段。
# ★★ **队号不在这一条链上**:播报只把**被击杀者的显示名**交给 `CombatFeedback.kill(名字)`,
#   屏幕上那行是「击杀 <名字>」,既没有队号也没有队色。队号在**记分条**(`TeamHud` 的
#   "A 队击杀 / B 队击杀")与**头顶 ID**(名字 + **队色**,同样不含队号文本)上。
#   **播报本身与 1v1 / 大乱斗**逐字同规则:只有 `killer == 我 且 victim != 我` 才播。
# ★★ **`killer == 0` 的倒地在 3v3 也不播**(队友误炸 / 溺水 / K 自杀这些无归因档)。
#   别拿"计分不分死因"去反推播报 —— 计分归属(A 册 `_scores` 给对方队 +1)与"屏幕上
#   要不要弹字"是两件事;这里曾有一条注释写着"3v3 也播",而代码从来没有那个分支
#   (注释讲的是动机、不是代码,本仓明确的缺陷类)。
func _on_kill_event(killer: int, victim: int) -> void:
	if victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零
	elif killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))


# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀,
# 但按「不分死因」给对方队 +1)。★ worker 侧闸门认 `_team_mode`(A 册收尾批接的)。
func _unhandled_input(event: InputEvent) -> void:
	if _match_ended or _local == null:
		return
	# ★ 判活再发(全仓纪律,与 `royale_game` 那处逐字同款):定向可靠包,连接可能已不可用。
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


# 回合状态(3v3):
#  - COUNTDOWN 且 round>1(新一轮):服务器已 `_reset_world_and_clear_dynamics()`(还原砖 +
#    清子弹 + 重铺地面武器 + 各人背包重置),这里同刻清本地子弹并复位砖,两端从同一基线出发。
#    ★ 并在同一处**重拉一次 `match_sync`** —— 见下面那一段注释(换边)。
#  - MATCH_OVER → 弹结算页,**玩家自己退**(不再是 6s 后自动回主菜单);记分/胜负播报仍由
#    `TeamHud` 负责(它画的是对局中的小记分条,结算页是终局那一屏,两者不冲突)。
func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var state := int(data.get("state", 0))
	_round_locked = state == 0
	if state == 0 and int(data.get("round", 1)) > 1:   # COUNTDOWN,新一轮
		for b in get_tree().get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()
		if _level0 != null and _level0.has_method("reset_destructibles"):
			_level0.reset_destructibles()
		# ★ 地面武器**不要在这里清**(与 1v1 逐字同款的理由):服务器换局是「先
		#   `_reset_ground_weapons`(广播 removed×旧 + spawned×新)、**再** `_broadcast_round_state`」,
		#   两条走同一条可靠通道、保序到达 —— 本条 round_state 到达时新一轮那批**早已在本地建好**,
		#   再清一次 = 第 2 局起客户端地面恒空。
		# ★★ 重拉 `match_sync`(控制者裁定,别自己另想):3v3 每局**整队换边**,而
		#   `TeamHost.role_spawns()` 返回的是**当下**那一份 —— 客户端只在进场/重连拉过一次,
		#   换边后六端手里那份是**旧侧**的。不补发 second path 进 round_state(那是给同一份数据开
		#   第二条投递路径,自检 B2 那类事故的形状),改在这里拉 —— 本来就站在"清子弹 + 还原砖"
		#   这一拍上,语义内聚,且顺带把 `ground_weapons`(服务器刚重铺)与 `destroyed`(刚还原成
		#   基线 → 服务器侧为空)一并对齐。
		if NetBus.can_send_to_server():
			# ★ 先置位再发:这条应答是**补态口径**(不是进场建态)—— 换边后 `spawns` 是**新一侧**
			#   而 `PvpSession.spawn` 手里是旧一侧,两者**必然**不一致,照进场口径硬拉 = 每局边界
			#   刷一条假告警 + 一次多余瞬移(位置本来就归 C2 权威)。闸门与"重连补态"共用
			#   (`_resync_pull_pending`,读一次即清),不要新立一个标志 —— 问的是同一个问题。
			_resync_pull_pending = true
			NetBus.rpc_id(1, "match_sync")
	elif state == 3:   # TeamHost.RoundState.MATCH_OVER(胜负已判:局胜或整队走光)
		# ★★ **刻意没有 `and not _match_ended` 这道闸**(与大乱斗不同,别照抄过来加对称):
		#   本模式的 MATCH_OVER **会有第二条载荷**,而结算页必须跟着刷新 ——
		#   `TeamHost._finish_match()` 在**战斗进行中**直接把 PLAYING→MATCH_OVER,而倒地边沿
		#   检测在 `match _round_state:` **之前**、且**不看状态** ⇒ 终局之后再死人会再广播一条
		#   带**新 `stats`/`mvp`** 的终局载荷(见基类 `_show_result` 的注释)。
		_match_ended = true
		# ★ ESC 菜单随即失效、退出只走结算页这一条路(与另两个客户端同款):不销毁菜单的话玩家能
		#   在结算页上再弹一次暂停菜单 —— 本页的 ESC(返回主菜单)与菜单的 ESC 会**同时**触发
		#   (见 `ui/match_result.gd` 类头那条硬依赖)。
		#   ★ 上一版这里还兼职"别让 6s 退场定时器在玩家已从别的路径离开后再切一次场景";定时器已
		#     换成结算页(那条风险改由 `MatchResult` 的 `leave_requested` 只发一次 +
		#     `safe_change_scene` 的 `_switching` 兜住),但**这两行仍然必须留** —— 上面的 ESC
		#     双重语义依赖它。
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
			_pause_menu = null
		# 结算页:玩家自己退(不再是 6 秒后自动回主菜单)。
		_show_result()
	_refresh_input_lock()   # 单一收口:三个维度任一成立即锁(见基类函数定义)


# 结算页载荷的唯一来源。★ 本函数只读状态、不碰节点树(适配器是纯函数)。
# `_last_round_state` 是**基类**成员(记录在同名函数开头),本文件不再声明。
func _build_result_payload() -> Dictionary:
	# ★ `my_team` 取自 `_team_of_role(PvpSession.role)` —— 队伍表从 `match_sync` 来;
	#   队号 0(表还没到)时 `_verdict_team` 念「失败」而不是谎报胜利。
	return MatchResultPayload.for_team(_last_round_state, _names, _teams,
			_team_of_role(PvpSession.role))


# ── 名字 / 颜色 ──
# 应用函数(不是信号回调):唯一入口 = `_on_match_sync`(进场拉取)。
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
	_ensure_id_label(PvpSession.role)
	_refresh_names()


func _ensure_id_label(role: int) -> void:
	if _world == null or _id_labels.has(role):
		return
	var lbl: Node2D = load("res://ui/world_label.gd").new()
	_world.add_child(lbl)
	_id_labels[role] = lbl


# 头顶名按**队色**上色(大乱斗那份是按 role 的 8 色板;1v1 那份是中性亮白)。
# ★ 自己那颗也按队色 —— 六个名字里"我在哪一队"要一眼看出,不需要靠记 role。
func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		(_id_labels[role] as Node2D).set_label(nm, _team_color(role))


func _process(_delta: float) -> void:
	# 头顶 ID / 血条贴放(独立于倒地转体)
	for role in _id_labels:
		var target: Node2D = _local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + ID_HEAD_OFFSET
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + Vector2(0.0, -116.0)


# 对手副本访问器(3v3:按 role 动态,同大乱斗)
func _all_replicas() -> Array:
	return _replicas.values()   # Beta 时间视效:遍历全部对手副本


func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null

extends Node

# 大乱斗 C2 探针的**观察者**(客户端子进程用;见 royale_c2_probe.gd 文件头)。
# 挂在 get_tree().root 上:换场(真 royale_lobby → 真 royale_game)不会把它带走 →
# 它能在**换场之后**读真 royale_game 实例的 C2 状态。
#
# 流程:
#   0/1  驱动真大厅(建房 / 加入房间),等换场到真 royale_game;
#   2    等对局进 PLAYING → c1 按一次 K(自杀脱困,走游戏自己的 _unhandled_input);
#   3/4  等「自己倒地」→ 等「自己复活」(服务器 2s 后复活并瞬移回出生点 —— 这次瞬移
#        客户端不可预测,正是要 reconcile 去收敛的那次服务器外部事件);
#   5    静置 SETTLE 秒后断言。
#
# 断言分两组:
# ── B 组 · 运行时(读**生产对象**的真状态):
#   · _rollback 存在,且 last_applied() ≥ MIN_LAST_APPLIED  —— 接线在推进(seq 与 note_post_step 都通了)
#   · c1:rollback_count() ≥ 1                              —— 复活那次外部事件确实触发了回滚
#   · 本地玩家与**权威快照**收敛:位置 ≤ POS_TOL 且倒地态一致  —— reconcile 真的在收敛(删掉即红)
#   · c1:观察到「倒地 → 复活」这条链走完
# ── A 组 · 源码级(生产目录零残留 + 一条禁区):
#   · 不存在 server_rendered / apply_server_snapshot / LOCAL_PREDICTION_ENABLED(设计 §0「彻底删干净」)
#   · royale_game 不得消费 round_state 的 `alive` —— 理由见 _check_no_alive_consume
#
# ★ 关于「K 自杀是不是广播的」——A 组第 2 条就是为了回答它:
#   · **请求**不广播:`NetBusExt.rpc_id(1, "suicide_request")` 定向发给 worker,无回执;
#   · **"谁死了/谁活着"确实广播**:倒地边沿 → `_broadcast_round_state()`,载荷带 `alive`({role: bool})
#     与 `deaths` —— 客户端读得到,今天唯一消费者是排行榜(scenes/royale_hud.gd)。
#   · 但 C2 下**不许**把它接去写本地玩家(第二条权威入口 + 并不更快),见断言的理由。
#   本探针的鉴别力正依赖这一点:若消费了 alive,删掉 reconcile 后本地玩家仍会被 alive 拉成"活着",
#   那条"分歧不收敛"的反证就失去信号。

const RESULT_PREFIX := "royale_c2_probe_"
const GO_FILE := "user://royale_c2_probe_go.txt"
const DEADLINE := 75.0
const SETTLE := 1.5              # 复活后静置(等 reconcile 收敛;快照 60Hz,1.5s 绰绰有余)
const MIN_LAST_APPLIED := 60     # 接线在推进的下限(换场到断言约 6s ≈ 360 tick,留 6 倍余量)
const POS_TOL := 100.0           # 收敛判据(px):快照滞后一 tick ≈ 11.7px,100 留足余量

# ── A 组:源码级(与运行时读数无关,但两支一起跑省一次进程)──
# 判据一律取**去注释视图**(注释不是代码:一句"这里以前调过 set_server_rendered"的注释既不能
# 让"在位"类断言变绿,也不能让"零残留"类断言变红)。
const RG := "res://scenes/" + "royale" + "_game.gd"
const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui", "res://render"]
const MIN_PROD_FILES := 40   # 扫到的源文件数下限:防"扫描坏了 → 零命中 = 假绿"
# 碎片拼接(与 kh_l6_probe 同一条纪律):别让针的字面量在自扫时自伤。
const N_SSR := "set_server" + "_rendered"
const N_LOCAL_PRED := "LOCAL_PREDICTION" + "_ENABLED"
const N_APPLY_SNAP := "apply_server" + "_snapshot("
# round_state 载荷里那个键的字面量(`"alive"`,带引号)。**切在词中间** —— 否则本文件自己的
# 源码里就出现了要找的那串字面量(虽然 tests/ 不在扫描根里,纪律照旧)。
const N_ALIVE_KEY := "\"ali" + "ve\""

var who := "c1"
var lobby: Node = null           # 真 royale_lobby.tscn 实例(本进程里被驱动的那份)

var _t := 0.0
var _stage := 0
var _stage_t := 0.0
var _game: Node = null           # 换场后的真 royale_game 实例
var _own_snap: Dictionary = {}   # 最新世界包里**自己**那一份(服务器权威渲染字段)
var _round_state := -1
var _saw_downed := false
var _respawned := false
var _logged_once: Dictionary = {}


func _ready() -> void:
	_log("观察者就绪(role=%s);真大厅实例=%s" % [who, str(lobby != null)])
	# 世界包里**自己**那一份 = 服务器权威(canonical pos / downed / hp)。C2 下客户端不再消费它,
	# 但作为**判据的地面真值**它正好:拿它和本地玩家的实际状态比,就知道收敛没收敛。
	NetBus.local_snapshot_world.connect(func(snap: Dictionary) -> void:
		var players_snap: Dictionary = snap.get("players", {})
		var mine: Dictionary = players_snap.get(str(PvpSession.role), {})
		if not mine.is_empty():
			_own_snap = mine)
	NetBus.local_round_state.connect(func(data: Dictionary) -> void:
		_round_state = int(data.get("state", -1)))


# 子进程的 stdout 不会被父进程继承(Windows CreateProcess 不继承句柄)→ 落盘一份,
# 父进程在失败/超时时把它打出来,否则客户端子进程里发生了什么完全看不见。
func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://%s%s.log" % [RESULT_PREFIX, who]
	# READ_WRITE 不会创建文件(文件不存在时 open 直接返回 null)→ 首次落盘用 WRITE 建出来
	var fmode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, fmode)
	if f != null:
		f.seek_end()
		f.store_line("%5.1fs %s" % [_t, msg])
		f.close()


func _log_once(msg: String) -> void:
	if _logged_once.has(msg):
		return
	_logged_once[msg] = true
	_log(msg)


func _process(delta: float) -> void:
	_t += delta
	if _t > DEADLINE:
		var cs := get_tree().current_scene
		_finish(false, "超时(阶段 %d;当前场景=%s)" % [_stage,
				"(空)" if cs == null else str(cs.name)])
		return
	_stage_t += delta
	match _stage:
		0:
			_stage_lobby()
		1:
			_stage_wait_game()
		2:
			_stage_playing()
		3:
			_stage_wait_downed()
		4:
			_stage_wait_respawn()
		5:
			if _stage_t >= SETTLE:
				_assert()


# ── 阶段 0:等真大厅连上大厅服 → c1 建房 / c2 等 GO 文件后加入 ──
func _stage_lobby() -> void:
	if lobby == null or not is_instance_valid(lobby):
		_log_once("等真大厅实例挂上(add_child 被推迟到帧末)")
		return
	if not bool(lobby.get("_connected")):
		_log_once("等大厅连接(_connected=false)")
		return   # 真大厅面板自己会连 127.0.0.1(_ready 里的 _request_list)
	if who == "c1":
		_log("大厅已连,建房")
		lobby.call("_on_create_pressed")   # 等价于点「创建房间」(公开房,人数上限默认 4)
		_stage = 1
		_stage_t = 0.0
		return
	if not FileAccess.file_exists(GO_FILE):
		return
	var f := FileAccess.open(GO_FILE, FileAccess.READ)
	var code: String = f.get_as_text().strip_edges() if f != null else ""
	if f != null:
		f.close()
	if code.is_empty():
		return
	_log("用房间号 %s 加入" % code)
	lobby.call("_join_room", code, "")   # 等价于点房间列表里的房间(公开房,邀请码空)
	_stage = 1
	_stage_t = 0.0


# ── 阶段 1:等换场(真大厅 → 真 royale_game)──
func _stage_wait_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_royale_game(cs):
		_log_once("等换场(当前场景=%s)" % ("(空)" if cs == null else str(cs.name)))
		return
	_game = cs
	_log("已换场到 royale_game(帧 %d)" % Engine.get_process_frames())
	_stage = 2
	_stage_t = 0.0


# ── 阶段 2:等 PLAYING(COUNTDOWN 3s;自杀只允许在对局进行中)──
func _stage_playing() -> void:
	if _game == null or not is_instance_valid(_game):
		_finish(false, "royale_game 实例失效")
		return
	if _game.get("_rollback") == null:
		# 接线没上 → 不必等 PLAYING:这一条本身就是本批要找的红。顺带把 A 组也跑掉 ——
		# "先红"那一步一次就能看到**全部**缺什么,而不是挤牙膏。
		var early: Array = ["royale_game 没有 _rollback 字段(C2 没接线)"]
		_check_residue(early)
		_check_no_alive_consume(early)
		_finish(false, " | ".join(early))
		return
	if _round_state != 1:
		_log_once("等 PLAYING(当前 round_state=%d)" % _round_state)
		return
	if who != "c1":
		_log("c2:对局已进入 PLAYING,只做接线与收敛断言(不自杀)")
		_stage = 5
		_stage_t = 0.0
		return
	# ★ 走**游戏自己的** K 键路径(不直接发 RPC):顺带把「_unhandled_input 的 K 分支还在」也验了。
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_K
	_game.call("_unhandled_input", ev)
	_log("c1:已按 K 请求自杀脱困(等服务器 2s 复活 + 瞬移回出生点)")
	_stage = 3
	_stage_t = 0.0


# ── 阶段 3:等自己倒地(证明自杀真的送达了服务器)──
func _stage_wait_downed() -> void:
	if bool(_own_snap.get("downed", false)):
		_saw_downed = true
		_log("c1:权威快照已显示自己倒地")
		_stage = 4
		_stage_t = 0.0
		return
	if _stage_t > 5.0:
		_finish(false, "按 K 后 5s 内权威快照仍是 downed=false(自杀没送达?)")
		return
	_log_once("c1:等权威快照显示 downed=true")


# ── 阶段 4:等自己复活(服务器 2s 复活并瞬移回出生点 = 客户端不可预测的那次外部事件)──
func _stage_wait_respawn() -> void:
	if bool(_own_snap.get("downed", true)):
		_log_once("c1:等复活(服务器 RESPAWN_DELAY=2s + 瞬移回出生点)")
		return
	_respawned = true
	_log("c1:权威快照已显示复活 → 静置 %.1fs 等 reconcile 收敛" % SETTLE)
	_stage = 5
	_stage_t = 0.0


func _is_royale_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("royale_game.gd")


# ── 阶段 5:断言(A 组源码级 + B 组运行时)──
func _assert() -> void:
	var problems: Array = []
	_check_residue(problems)
	_check_no_alive_consume(problems)
	var rb = _game.get("_rollback")
	if rb == null:
		problems.append("royale_game 没有 _rollback(C2 没接线)")
	else:
		var la: int = int(rb.last_applied())
		if la < MIN_LAST_APPLIED:
			problems.append("last_applied=%d < %d(seq 或 note_post_step 没接上 → 预测整态没进 ring)"
					% [la, MIN_LAST_APPLIED])
		if who == "c1":
			var rc: int = int(rb.rollback_count())
			if rc < 1:
				problems.append("rollback_count=0(复活瞬移这次服务器外部事件没触发回滚 → reconcile 没在跑)")
	var local: Node2D = _game.get("_local")
	if local == null or not is_instance_valid(local):
		problems.append("拿不到本地玩家(场景没建好?)")
	elif _own_snap.is_empty():
		problems.append("没收到含自己那份的世界包(判据的地面真值缺失)")
	else:
		var d: float = MazeGenerator.toroidal_delta_px(local.global_position,
				_own_snap.get("pos", local.global_position),
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d > POS_TOL:
			problems.append("本地玩家与权威快照**未收敛**:相差 %.1f px > %.0f(reconcile 没把分歧拉回)"
					% [d, POS_TOL])
		var snap_downed := bool(_own_snap.get("downed", false))
		if snap_downed != local.is_downed():
			problems.append("倒地态与权威不一致:快照 downed=%s,本地 %s(reconcile 没把复活拉回来)"
					% [str(snap_downed), str(local.is_downed())])
		if who == "c1" and not _respawned:
			problems.append("没观察到「倒地 → 复活」这条链走完(_saw_downed=%s)" % str(_saw_downed))
	var rb_txt := "无" if rb == null else "last_applied=%d rollback=%d" % [
			int(rb.last_applied()), int(rb.rollback_count())]
	var pos_txt := "n/a"
	if local != null and is_instance_valid(local):
		pos_txt = "本地=%s 权威=%s" % [str(local.global_position), str(_own_snap.get("pos", Vector2.ZERO))]
	var detail := "role=%d %s round_state=%d %s%s" % [PvpSession.role, rb_txt, _round_state, pos_txt,
			"" if problems.is_empty() else " | " + "; ".join(problems)]
	_finish(problems.is_empty(), detail)


# ══ A 组 · 源码级 ═══════════════════════════════════════════════════

# ── A①:生产目录零残留 ──
# 设计 §0 的删除裁定是「**彻底删干净**:终态只有一套联机模型」。这三样是旧路径的全部构件:
#   server_rendered / set_server_rendered / apply_server_snapshot —— 服务器渲染一族(§3A)
#   LOCAL_PREDICTION_ENABLED —— 1v1 那条"翻个常量就回落"的双路开关(§3B)
# 残留**不一定报错**:"字段还在但没人用"完全是静默的,而它正是"还有第二套模型"的存在形式。
# 故做成无条件判据。★ 反证已实跑:在 royale_game 里加回一行 set_server_rendered → 红。
func _check_residue(problems: Array) -> void:
	var files := _scan_prod()
	if files.size() < MIN_PROD_FILES:
		problems.append("源码扫描只扫到 %d 个文件(<%d)→ 零命中不可信(扫描坏了?)" % [
				files.size(), MIN_PROD_FILES])
		return
	var hits := 0
	for needle in [N_SSR, N_LOCAL_PRED, N_APPLY_SNAP]:
		for path in files:
			if str(files[path]).contains(needle):
				hits += 1
				problems.append("生产目录残留旧路径构件 `%s`:%s(设计 §0 要求彻底删干净)" % [needle, path])
	_log("A①:扫了 %d 个生产源文件,零残留 %s" % [files.size(), "✓" if hits == 0 else "✗(%d 处)" % hits])


# ── A②:不得消费 round_state 的 `alive`(一条**禁区**,理由见下)──
# 服务器在倒地边沿会广播 round_state,载荷里带 `alive`({role: bool})—— 也就是说"你死了/
# 你活了"这件事**是广播的**,客户端读得到(今天唯一消费者是排行榜 scenes/royale_hud.gd)。
# ★ C2 下**不许**把它接去写本地玩家,两条理由:
#   ① 那是**第二条权威入口**:C2 的纪律是权威状态只经 on_authoritative → restore_state + 重放
#      进来。绕过它的"顺手补上"正是被删掉的那条旧路径的写法,会重新引入橡皮筋;
#   ② 它**并不更快** —— 同样是服务器往返广播,只是换了条通道(反过来说:它连"更快"这个
#      唯一可能的理由都没有)。
# 本探针的**鉴别力也依赖这条**:若消费了 alive,删掉 reconcile 后本地玩家仍会被 alive 拉成
# "活着" → 那条"分歧不收敛"的反证就失去信号。
# 判据取**全文零出现**这个键。若日后真要在 royale_game 里用 alive 做别的事(观战/结算),
# 把判据改成"不得写进 _local"的形态并同步改本注释 —— 别直接删掉这条门。
func _check_no_alive_consume(problems: Array) -> void:
	var code := _code_view(_read(RG))
	if code.is_empty():
		# 读不到源文件时**不能**判绿:那正是"零命中 = 假绿"的形状
		problems.append("读不到 %s → A② 无从判定(不判绿)" % RG)
		return
	if code.contains(N_ALIVE_KEY):
		problems.append("royale_game.gd 里出现了 round_state 的 %s 键(C2 下不许接它写本地玩家,理由见 tests/royale_c2_watcher.gd 的 _check_no_alive_consume)" % N_ALIVE_KEY)
	else:
		_log("A②:royale_game 未消费 round_state 的 alive ✓")


# ── 源码扫描的小工具(与 kh_l6_probe 同源,砍到够用为止)──
func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 去注释视图:丢掉纯注释行,**保留缩进**(结构类判据靠缩进定块)
func _code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := _strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 删掉一行里字符串字面量之外的 `#` 起、到行尾的注释
func _strip_line_comment(line: String) -> String:
	var quote := ""
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line


# 生产目录下全部 .gd 的**去注释**源码 {path: code}
func _scan_prod() -> Dictionary:
	var out := {}
	var stack: Array[String] = []
	for d in PROD_DIRS:
		stack.append(d)
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var da := DirAccess.open(dir_path)
		if da == null:
			continue
		da.list_dir_begin()
		var n := da.get_next()
		while n != "":
			if da.current_is_dir():
				if not n.begins_with("."):
					stack.append(dir_path + "/" + n)
			elif n.ends_with(".gd"):
				out[dir_path + "/" + n] = _code_view(_read(dir_path + "/" + n))
			n = da.get_next()
		da.list_dir_end()
	return out


func _finish(ok: bool, msg: String) -> void:
	_log(("OK " if ok else "FAIL ") + msg)
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, who], FileAccess.WRITE)
	if f != null:
		f.store_string(("OK " if ok else "FAIL ") + msg)
		f.close()
	get_tree().quit(0 if ok else 1)

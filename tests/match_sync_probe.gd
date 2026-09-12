extends Node

# 进场拉取(match_sync)探针(场景模式:要真地图 + 真 Player)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/match_sync_probe.tscn
# 期望:末行 "MATCH SYNC PROBE: ALL-OK"。判据 grep 该文本,不只看退出码。
#
# 存在理由:开局三载荷(昵称/色相/生效选项)原先靠"服务器**推** → 大厅缓存 → 新场景取用",
# 而推的根因问题是「推给一个正在切场景的客户端」—— 服务器在**同一次 poll** 里推 4 条,
# 那一刻新场景的订阅方一个都不存在(B2)。改成新场景进场**主动拉**,方向反转,竞态不存在。
# 拉取的载荷里带 `spawns`(各 role 出生点),它必须与**服务器实际摆位用的那份**同源 ——
# 否则客户端在自己那份出生点上、服务器把玩家摆在另一处(§3G 刚修过同一类错误)。
#
# 本探针钉:**`role_spawns()` 如实反映本局各 role 的出生点**,1v1 与大乱斗两条路径都对。
# 注意:这里**不把宿主加进树**(不 add_child)—— `_ready` 会广播、在无多人连接时刷 RPC 错误;
# `_init` 已经把玩家与世界建好了,足够断言。
#
# ⚠ 判据 grep 文本 "MATCH SYNC PROBE: ALL-OK"。

const MAP := "res://maps/factory1v1.cyrm"

# 大乱斗侧故意用一组不像平面地板格的值:若被重算(plan_spawns 洗牌取地板格)必然不同
const ROYALE_GIVEN := {1: Vector2i(7, 8), 2: Vector2i(60, 70)}

var _failures: Array[String] = []
var _ran: Dictionary = {}


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[sync]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[sync]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[sync]   ✗ %s" % msg)


# 完成戳防线:Godot 的运行时错误只中断当前函数,调用它的 `_ready()` 照常往下走 →
# 「测试函数中途报错、一条 _check 都没跑到、却照样打印 ALL-OK」。故每个测试函数最后一行盖戳。
func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _ready() -> void:
	_test_1v1_spawns()
	_require_ran("duel")
	_test_royale_spawns()
	_require_ran("royale")
	_check_no_pending_handoff()
	if _failures.is_empty():
		print("MATCH SYNC PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MATCH SYNC PROBE: FAIL")
		for f in _failures:
			print("[sync]   ✗ %s" % f)
		get_tree().quit(1)


# ── 1v1:各 role 的出生点来自地图的 # player / # player2(# 换边时对调)──
func _test_1v1_spawns() -> void:
	var host: Node = MatchHost.new(MAP, {1: 1, 2: 2})
	var sp: Dictionary = host.role_spawns()
	var on_map: Dictionary = MazeGenerator.load_spawns()
	_check(sp.size() == 2 and sp.has(1) and sp.has(2),
			"1v1: role_spawns 覆盖本局全部 role(得 %s)" % str(sp))
	# 两个 role 各自落在图上标定的两个出生点里(换边只影响谁拿哪个,不影响"恰好这两个")
	var want: Array = [on_map.get("player", Vector2i(-1, -1)), on_map.get("player2", Vector2i(-1, -1))]
	var got: Array = [sp.get(1, Vector2i(-9, -9)), sp.get(2, Vector2i(-9, -9))]
	got.sort()
	want.sort()
	_check(got == want, "1v1: 两个出生点就是地图标定的 player/player2(得 %s,应为 %s)" % [
			str(got), str(want)])
	host.queue_free()
	_ran["duel"] = true   # ★ 完成戳必须在最后一行(见上方说明)


# ── 大乱斗:必须是 start_on 算好传进来的**那一份**(不得重算 —— 见 royale_spawn_plan_probe)──
func _test_royale_spawns() -> void:
	var host: Node = RoyaleHost.new(MAP, {1: 1, 2: 2}, {}, [], ROYALE_GIVEN)
	var sp: Dictionary = host.role_spawns()
	_check(sp == ROYALE_GIVEN or (sp.size() == ROYALE_GIVEN.size() and
			sp.get(1, Vector2i(-9, -9)) == ROYALE_GIVEN[1] and
			sp.get(2, Vector2i(-9, -9)) == ROYALE_GIVEN[2]),
			"大乱斗: role_spawns 就是传入的开局散点(得 %s,应为 %s)" % [str(sp), str(ROYALE_GIVEN)])
	# ★ 还要证明它**不是** respawn 路径:再次调用必须给同一份(基类 _spawn_cell 第二次会返回
	#   动态复活点,那正是必须覆写本方法的原因 —— 覆写漏了这里就会红)
	_check(host.role_spawns() == sp,
			"大乱斗: 重复取用返回同一份(未走动态复活点路径)")
	host.queue_free()
	_ran["royale"] = true   # ★ 完成戳必须在最后一行


# ── 反向守卫:交接机制必须彻底消失 ──
# 名单里是「推 → 大厅缓存 → 新场景取用」那条路的全套标识符。留着任何一处都说明只删了一半 ——
# 而那正是这套机制的历史故障模式(两条投递路径并存时只改一条 = 静默丢失,自检 B2)。
# 跳注释行:注释里提这些名字是**有意的**(留档为什么换掉)。
const FORBIDDEN := ["pending_peer_info", "pending_peer_hues", "pending_match_options",
		"clear_pending_payloads", "_consume_pending_payloads"]


func _check_no_pending_handoff() -> void:
	for d in ["res://core", "res://scenes", "res://server"]:
		for f in _gd_files(d):
			var txt := FileAccess.get_file_as_string(f)
			for line in txt.split("\n"):
				var t: String = line.strip_edges()
				if t.is_empty() or t.begins_with("#"):
					continue
				for bad in FORBIDDEN:
					if t.contains(bad):
						_fail("%s 里仍有交接机制标识符 %s(只删了一半?)" % [f, bad])
						return


func _gd_files(dir_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir_path + "/" + n
		if d.current_is_dir():
			if n != "." and n != "..":
				out.append_array(_gd_files(full))
		elif n.ends_with(".gd"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()
	return out

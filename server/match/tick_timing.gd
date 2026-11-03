extends RefCounted

# O0(bullet-perf 计划 `docs/superpowers/plans/2026-11-01-bullet-perf.md` §O0)· 服务器 tick 分段计时。

# 会被逐段累计的段名(**配对的是 MatchHost 里的调用点**,改名要两边一起改):
const SECTIONS: Array[StringName] = [&"adjudicate", &"own_snap", &"world_snap", &"rewind"]

# 是否累计。**构造时问一次 `NetDiag.enabled()`**(它自己懒查一次就缓存:命令行 `--diag` / `CYR_DIAG=1` /
# 导出服务端默认开)⇒ MatchHost 不必在 `_ready` 里再多一处接线,默认路径只有本文件这一个判据。
# ★ 探针要强开就构造后直接 `on = true`(别改本行:那会让"默认关"变得不确定)。
var on := NetDiag.enabled()

var _win_at := 0        # 本窗口起点(usec;0 = 还没开始)
var _ticks := 0
var _tick_sum := 0      # 整 tick 累计(usec)
var _tick_max := 0
var _bullets_sum := 0
var _bullets_max := 0
var _players := 0
var _sum: Dictionary = {}    # section -> usec 累计
var _max: Dictionary = {}    # section -> 单次最长(usec)
var _runs: Dictionary = {}   # section -> 本窗口调用次数


## 取一个起始戳。**关闭时返回 -1**(调用方原样交给 `end`/`end_tick`,它们见 -1 就返回)。
func begin() -> int:
	if not on:
		return -1
	return Time.get_ticks_usec()


## 收一段。`t0` 为 -1(未启用)⇒ 空实现。
func end(section: StringName, t0: int) -> void:
	if not on or t0 < 0:
		return
	var usec := Time.get_ticks_usec() - t0
	_sum[section] = int(_sum.get(section, 0)) + usec
	_runs[section] = int(_runs.get(section, 0)) + 1
	if usec > int(_max.get(section, 0)):
		_max[section] = usec


## 整 tick 收尾:记总时长 + 本 tick 的子弹数/玩家数;窗口到点就吐一行。
## ★ `players` 直接传引用(Dictionary),`host` 只在**本函数**里用来数 bullet 组 —— 关闭时这两件事都不做。
func end_tick(t0: int, players: Dictionary, host: Node) -> void:
	if not on or t0 < 0:
		return
	var now := Time.get_ticks_usec()
	var usec := now - t0
	_ticks += 1
	_tick_sum += usec
	if usec > _tick_max:
		_tick_max = usec
	_players = players.size()
	# 子弹数:与裁决遍历的是同一个组(60Hz 一次 get_nodes_in_group 只在开诊断时发生)。
	var bullets := 0
	if host != null and host.is_inside_tree():
		bullets = host.get_tree().get_nodes_in_group("bullet").size()
	_bullets_sum += bullets
	if bullets > _bullets_max:
		_bullets_max = bullets
	if _win_at == 0:
		_win_at = now
		return
	if now - _win_at < NetDiag.metric_interval_ms() * 1000:
		return
	_emit(now)


func _emit(now: int) -> void:
	if _ticks > 0:
		var ticks := _ticks
		var tick_avg := float(_tick_sum) / float(ticks)
		var d := {
			"interval_ms": (now - _win_at) / 1000,
			"ticks": ticks,
			"players": _players,
			# 每 tick 摊到的子弹数(峰值另列):判"这局同时在场的子弹数",别拿末帧读数代表整窗。
			"bullets_avg": roundi(float(_bullets_sum) / float(ticks)),
			"bullets_max": _bullets_max,
			"tick_avg_us": roundi(tick_avg),
			"tick_max_us": _tick_max,
		}
		for section in SECTIONS:
			# 三段口径分开列,别混读:
			var avg := float(int(_sum.get(section, 0))) / float(ticks)
			d["%s_runs" % section] = int(_runs.get(section, 0))
			d["%s_avg_us" % section] = roundi(avg)
			d["%s_max_us" % section] = int(_max.get(section, 0))
			d["%s_pct" % section] = snappedf(avg * 100.0 / maxf(tick_avg, 1.0), 0.1)
		NetDiag.log_metric("tick_sections", d)
	_reset(now)


func _reset(now: int) -> void:
	_win_at = now
	_ticks = 0
	_tick_sum = 0
	_tick_max = 0
	_bullets_sum = 0
	_bullets_max = 0
	_players = 0
	_sum.clear()
	_max.clear()
	_runs.clear()

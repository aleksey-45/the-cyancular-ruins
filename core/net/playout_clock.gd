class_name PlayoutClock
extends RefCounted

# 客户端**播放时钟**(按服务器 tick 计)。副本位置从"朝最新目标追赶"改成"在固定 playout 之后的
# 时刻做夹逼插值"之后,由它回答一个问题:**此刻该渲染服务器历史的哪一 tick**。
#
# ★★ 为什么不能"每收一包就把它重置到 `latest - playout`" —— 这是本类存在的**全部理由**:
#   2026-09-22 那套「双快照 tick 域 alpha 插值」就是这么写的(`push()` 把渲染时钟重置到 `latest - 1`),
#   在 60fps 渲染 + 60Hz 快照下 ⇒ **缓冲深度恒为 0** ⇒ 插值退化成"直接画最新包的原值" ⇒
#   对手的平滑度 == 包的**到达**平滑度(抖动 ±8ms 时约一半的帧零位移、另一半走两步)——
#   用户当时的原话是「位置一跳一跳,看起来敌方掉帧」。**别把那个错误抄回来。**
#   ⇒ 本类的规矩:**只在第一个包上做一次初始化,之后再不重置**;
#     渲染时刻由**自己按 60Hz 推进**(与包何时到达无关),包只用来更新 `latest` 并做**小幅纠偏**。
#
# ★ 纠偏(±`DRIFT_MAX`)是 time dilation 的**最小形态**:服务器与客户端是两个时钟(负载/帧率不同),
#   不纠偏就会**线性累积** —— 缓冲要么被吃穿(画面冻结)、要么越涨越大(延迟无上限)。
#   ★ 下界恒 > 0(`1 - DRIFT_MAX`)⇒ `render_tick` **单调不减**:播放历史**不许倒退**。
#
# ★ 判据:`tests/smoke/playout_clock_smoke.gd`(每帧推进 / 停流后仍单调推进 / 快 1% 的服务器下能追回)。
#   动这个文件必须先跑它。

const TICKS_PER_SEC := 60.0   # 与 `MatchState.SNAPSHOT_INTERVAL`(1/60)同源;引擎物理也是 60Hz
const DRIFT_MAX := 0.05       # 每秒最多快/慢 5%

var render_tick := 0.0        # 本帧要渲染的历史时刻(服务器 tick 域,可以是小数 = 夹在两条快照之间)
var _playout := 0
var _latest := -1             # 收到过的最新快照 tick
var _started := false


func _init(playout_ticks: int) -> void:
	# playout = 我们故意落后服务器多少 tick(缓冲深度)。0 = 不缓冲(等于贴最新,见文件头)。
	_playout = maxi(0, playout_ticks)


## 收到一个世界包。★ **只更新 `latest`**;唯一的例外是**第一个包**——那时还没有任何历史可放,
## 必须给 `render_tick` 一个起点(否则它会从 0 开始追,追到之前一直在渲染空地)。
func on_snapshot(tick: int) -> void:
	_latest = maxi(_latest, tick)
	if not _started:
		render_tick = float(_latest - _playout)
		_started = true


## 每帧推进一步。`delta` 是**渲染**帧间隔(秒)⇒ 帧率无关。
## ★ 单调性由"步长恒正"保证:`1.0 + clamp(err, -DRIFT_MAX, +DRIFT_MAX) ≥ 1 - DRIFT_MAX > 0`。
func advance(delta: float) -> void:
	if not _started:
		return
	var target := float(_latest - _playout)
	var err := target - render_tick
	render_tick += (1.0 + clampf(err, -DRIFT_MAX, DRIFT_MAX)) * delta * TICKS_PER_SEC


## 纠偏误差(正 = 我们落后目标,负 = 我们超前)。读数用;判据不直接断它。
func error_ticks() -> float:
	return float(_latest - _playout) - render_tick


## 是否已收到过至少一个快照(没收到之前 `render_tick` 没有意义)。
func started() -> bool:
	return _started


func playout_ticks() -> int:
	return _playout

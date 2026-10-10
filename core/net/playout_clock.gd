class_name PlayoutClock
extends RefCounted

# 客户端**播放时钟**(按服务器 tick 计)。副本位置走"固定 playout 之后的夹逼插值"之后,
# 由它回答一个问题:**此刻该渲染服务器历史的哪一 tick**。
#
# ★★ **参考不是"最新收到的包"**(2026-10-09 改)。上一版把目标设成 `latest − playout`(`latest` = 最新已收到 tick),
#   于是时钟在**追一个锯齿**:实测(3000 帧固定种子,真实现)±16ms 抖动下 p95/max 的超出量是 **+5.8 tick,
#   且与 playout 4/6/8 无关(5.8/5.8/5.7)** —— 均值对(恒为 `playout − 0.93`)、尾巴全是这个锯齿贡献的。
#   而**没有任何一手来源主张把目标设成最新样本**:NTP 是"从一窗样本里挑**最小 delay**那一格"(RFC 5905 §10),
#   RTP 是对到达偏差做**一阶平滑**(RFC 3550 §6.4.1/A.8),Valve/Bernier 2003 是"`客户端时间 − 插值延迟`"
#   —— 后者甚至明说"**向最新目标移动**的插值方案在包间隔不固定时**表现更差**"(正是本仓旧实现)。
#   依据与逐条出处:[`docs/eng/netcode-playout-clock-sync-sources.md`](../../docs/eng/netcode-playout-clock-sync-sources.md)。
#
# **现在的做法(三段,都能挂来源)**:
#   ① **观测**:每个包给一个"服务器 tick 时间轴落在本地时钟哪儿"的观测 `o = local_ms − tick × 16.667`,
#      `o` 越小 = 这条路径延迟越小(排队短)。
#   ② **鲁棒参考**:取最近 `WINDOW`(8)个观测的**最小值**(NTP §10 的选样形态)。迟到的包只能给出
#      **更大的** `o`,动不了参考 —— 这正是要的。且 `o` 的**长期漂移本身就是两端速率差** ⇒ 目标自动跟着
#      服务器速率走,**不需要显式的频率状态**(顶掉了上一版"只有相位项 ⇒ 持续速率失配必然留常驻误差"的病)。
#   ③ **深度跟着观测走**(`_depth_comp()`):`o_min` 挑的是"排队最短"那条路径 ⇒ 它**高估**服务器时间轴的位置
#      ⇒ 光用它,有效缓冲比名义 `playout` **更浅**(实测:名义 4 在 ±8/±16ms 下单帧最大位移顶到 10.0px,
#      上限 8.0)。⇒ 用窗口**展布**(`o_max − o_min`)的 **1.5 倍**(实测选的,见 `_depth_comp`)补回来。这就是"深度按观测到的抖动设定"
#      (Ramjee 1994 摘要的"按尖峰自适应"、Gaffer 的 2×/3× 发送间隔、RTP 的抖动估计同族)。
#   目标 = `(local_ms − o_min) / 16.667 − playout − 深度补偿`(Valve 的形式,offset 是**测出来**的)。
#
# ★ 时间源是**自己的** `_local_ms`,由 `advance(delta)` 推进(不是墙钟)⇒ **帧率无关、且可被夹具驱动**
#   (探针手动调 `_process(DT)` 就能造出一条模拟时间轴;用墙钟的话探针的抖动夹具会失效)。
# ★ `render_tick` **单调不减**:步长恒 `1 ± DRIFT_MAX > 0`;参考往上跳时只会让误差变负、让时钟快一点追,
#   不会让它倒退。
#
# ★ 判据:`tests/smoke/playout_clock_smoke.gd`(每帧推进 / 抖动+乱序到达下单调且停流仍推进 / 纠偏 /
#   **参考非最新**)。动这个文件必须先跑它。

const TICKS_PER_SEC := 60.0          # 与 `MatchState.SNAPSHOT_INTERVAL`(1/60)同源;引擎物理也是 60Hz
const TICK_MS := 1000.0 / 60.0       # 一个 tick 多少毫秒(观测换算用)
const WINDOW := 8                    # NTP §10 的窗口大小(8 级移位寄存器)
const DRIFT_SLACK := 1.5             # tick:误差死区(落在这里面**不纠偏**)—— 挡住残余抖动
const DRIFT_MAX := 0.10              # 每秒最多快/慢 10%(time dilation 的上限)
const DRIFT_GAIN := 0.25             # 死区外按比例纠偏的增益
const DEPTH_COMP_MAX := 4.0          # 深度补偿的上限(tick)

var render_tick := 0.0               # 本帧要渲染的历史时刻(服务器 tick 域,可为小数 = 夹在两条快照之间)

var _playout := 0
var _local_ms := 0.0                 # 本地单调毫秒(模拟时间;见文件头)
var _offsets: Array[float] = []      # 最近 WINDOW 个观测 `local_ms - tick * TICK_MS`
var _o_min := 0.0                    # 窗口内最小观测(= 延迟最小那条路径)
var _o_max := 0.0                    # 窗口内最大观测(诊断 + 深度补偿用)
var _started := false


func _init(playout_ticks: int) -> void:
	# playout = 我们故意落后服务器多少 tick(缓冲深度;实际深度还会加 `_depth_comp()`)。0 = 不缓冲。
	_playout = maxi(0, playout_ticks)


## 收到一个世界包。★ 只记一个**观测**;唯一的例外是第一个包——那时要给 `render_tick` 一个起点。
func on_snapshot(tick: int) -> void:
	var o := _local_ms - float(tick) * TICK_MS
	if not _started:
		_offsets = [o]
		_o_min = o
		_o_max = o
		_started = true
		render_tick = target_tick()
		return
	_offsets.append(o)
	while _offsets.size() > WINDOW:
		_offsets.pop_front()
	_o_min = _offsets[0]
	_o_max = _offsets[0]
	for v in _offsets:
		_o_min = minf(_o_min, v)
		_o_max = maxf(_o_max, v)


## 深度补偿:**窗口展布的 1.5 倍**(理由见文件头 ③)。
## ★ 系数 0.5 → 1.5 是**实测选的**(2026-10-09 仓主裁定 A 档):扫 k = 0.5/1.0/1.5 ⇒
##   k=0.5 在 ±8ms 下单帧最大位移顶到 **10.0px**(闸 8.0)、FAIL;k=1.5 时三档全绿。
func _depth_comp() -> float:
	if _offsets.size() < 2:
		return 0.0
	return clampf(roundf((_o_max - _o_min) / TICK_MS * 1.5), 0.0, DEPTH_COMP_MAX)


## 本帧的参考(我们要让 `render_tick` 跟上的那个值)。★ 读数 / 判据都用它,不许拿 `latest` 顶替。
func target_tick() -> float:
	return (_local_ms - _o_min) / TICK_MS - float(_playout) - _depth_comp()


## 每帧推进一步。`delta` 是**渲染**帧间隔(秒)⇒ 帧率无关。
## ★ 单调性由"步长恒正"保证:`1.0 + clampf(纠偏, -DRIFT_MAX, +DRIFT_MAX) ≥ 1 - DRIFT_MAX > 0`。
func advance(delta: float) -> void:
	if not _started:
		return
	_local_ms += delta * 1000.0
	var err := target_tick() - render_tick
	var corr := 0.0
	if absf(err) > DRIFT_SLACK:
		# 只纠**超出死区**的那部分(比例 + 上限)。死区内 corr 恒 0 ⇒ 推进恰 1.0 tick/帧。
		corr = clampf((err - signf(err) * DRIFT_SLACK) * DRIFT_GAIN, -DRIFT_MAX, DRIFT_MAX)
	render_tick += (1.0 + corr) * delta * TICKS_PER_SEC


## 纠偏误差(正 = 我们落后参考)。读数用;判据不直接断它。
func error_ticks() -> float:
	return target_tick() - render_tick


## 窗口内最小观测(毫秒)。诊断用。
func offset_min_ms() -> float:
	return _o_min


## 是否已收到过至少一个快照(没收到之前 `render_tick` 没有意义)。
func started() -> bool:
	return _started


func playout_ticks() -> int:
	return _playout

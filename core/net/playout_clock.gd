extends RefCounted
# ★ 刻意不写 class_name:它只被 player_replica 用 `preload(...)` 取一个常量。写成全局类名要多一次编辑器扫描才注册得进
# 全局类缓存(运行 / 导出两面都要那份缓存),而 preload 不受缓存状态影响 —— 导出后不会突然「找不到类型 PlayoutClock」。

# 客户端播放时钟(按服务器 tick 计):回答"此刻该渲染服务器历史的哪一 tick"。
# ★ 参考不是"最新收到的包":观测 o = local_ms − tick × TICK_MS,参考取最近 WINDOW(8) 个观测的最小值 —— 迟到包只给更大的
#   o、动不了参考;o 的长期漂移本身就是两端速率差,故不需要显式的频率状态(NTP RFC 5905 §10 / RTP RFC 3550 §6.4.1 /
#   Valve 的"客户端时间 − 插值延迟",出处见 docs/eng/netcode-playout-clock-sync-sources.md)。
# ★ 时间源是自己的 _local_ms、由 advance(delta) 推进(不是墙钟)⇒ 帧率无关、可手动驱动;render_tick 单调不减。
# ★ 它只服务远端玩家副本的渲染位置(scenes/player/player_replica.gd):让 30Hz 的离散位置在两条快照之间夹逼插值;幽灵碰撞体不跟它(预测面要最小陈旧)。零守卫:视觉观感不写守卫,见 docs/eng/tests.md。

const TICKS_PER_SEC := 60.0          # 与 `MatchState.SNAPSHOT_INTERVAL`(1/60)同源;引擎物理也是 60Hz
const TICK_MS := 1000.0 / 60.0       # 一个 tick 多少毫秒(观测换算用)
const WINDOW := 8                    # NTP §10 的窗口大小(8 级移位寄存器)
const DRIFT_SLACK := 1.5             # tick:误差死区(落在这里面不纠偏)—— 挡住残余抖动
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
	_playout = maxi(0, playout_ticks)


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


## 深度补偿:窗口展布的 1.5 倍(系数实测选的:k=0.5 时单帧最大位移 10.0px 超闸 8.0;光用 o_min 会让有效缓冲比名义 playout 更浅)。
func _depth_comp() -> float:
	if _offsets.size() < 2:
		return 0.0
	return clampf(roundf((_o_max - _o_min) / TICK_MS * 1.5), 0.0, DEPTH_COMP_MAX)


func target_tick() -> float:
	return (_local_ms - _o_min) / TICK_MS - float(_playout) - _depth_comp()


## 每帧推进一步(delta = 渲染帧间隔,秒)。★ 单调性由步长恒 1 ± DRIFT_MAX > 0 保证。
func advance(delta: float) -> void:
	if not _started:
		return
	_local_ms += delta * 1000.0
	var err := target_tick() - render_tick
	var corr := 0.0
	if absf(err) > DRIFT_SLACK:
		corr = clampf((err - signf(err) * DRIFT_SLACK) * DRIFT_GAIN, -DRIFT_MAX, DRIFT_MAX)
	render_tick += (1.0 + corr) * delta * TICKS_PER_SEC

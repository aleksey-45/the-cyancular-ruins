class_name SnapshotInterp
extends RefCounted

# 双快照 + tick 域 alpha 位置插值(副本渲染用)。`player_replica` / `enemy_replica` 逐字同款,
# 2026-09-14 收为单一来源(此前两份已轻微分叉:时钟变量名、数组类型化、注释)。
#
# ★ 为什么值得单独成类:这是**环面插值**的热点,CLAUDE.md 专门记过教训 —— 旧实现用"自身差分
#   追赶",当渲染位置与目标相隔整幅地图时最短向量=0,副本一旦落到远副本就永远留在那儿
#   (对手被渲染到屏幕外「看不见」)。现行做法是:时钟只在 tick 域走 + 双快照插值 +
#   由**调用方**把结果锚到本地玩家最近副本(本类不做锚定,那是副本类的职责)。
#   两份实现并存时,下一处修正(例如丢包时改成外推)只会改到其中一份,表现是
#   「对手位置平滑、鸟位置抖」这种极难归因的差异。
#
# ★ 不引 autoload(地图尺寸由构造参数传入)→ 可被 `-s` 冒烟 load,故算法本身有行为测试:
#   `tests/snapshot_interp_smoke.gd`(含**跨接缝必须走最短向量**那条 —— 写成朴素 lerp 必红)。
#   同族约定见 core/water.gd、core/math_util.gd、core/collision_aabb.gd 的文件头。
#
# 时钟语义:每收一个新快照就把时钟重置到「最新 - 1」起点,之后各帧按真实时间(tick 域)累进
# 扫完这个最新区间(tick 越密集 / 渲染帧越多,alpha 越细分越平滑)。时钟越过最新(丢包/卡顿
# 间隙)→ **冻结在最新已收位置**;快照续上重置即恢复 —— 不累积漂移、不回退。不依赖两端时钟
# 同步(服务器恒定 SNAPSHOT_HZ)。

const SNAPSHOT_HZ := 60.0   # 服务器快照频率(恒定):渲染时钟的时间轴刻度,与 tick 一一对应

var _keep_ticks: int
var _map_w: float
var _map_h: float
var _pos_hist: Dictionary = {}   # 服务器 tick(int) → canonical 位置(只留最近 _keep_ticks)
var _tick_list: Array = []       # _pos_hist 的键升序缓存(小数组,推入后重建)
var _last_tick := 0              # 已入缓冲的最大 tick(丢弃乱序/重复)
var _clock := -1.0               # 渲染时钟(tick 域,浮点);<0 = 缓冲未满、尚未起步


# keep_ticks = 位置缓冲保留窗口(最新前 N tick,含最新 → 实际 N+1 条;够插值 + 顶住小丢包)。
# 调用方各取所需:玩家副本取 8(对手要更长的抗抖动窗);原中立鸟副本取 4,该副本随特性一并删除。
# map_w/map_h = 地图像素尺寸:插值要取最短向量(跨接缝),需要它才能不引 autoload。
func _init(keep_ticks: int, map_w: float, map_h: float) -> void:
	_keep_ticks = keep_ticks
	_map_w = map_w
	_map_h = map_h


# 入缓冲:只收**递增** tick(乱序/重复丢弃)。每收一个新快照就把时钟重置到「最新 - 1」起点。
func push(tick: int, pos: Vector2) -> void:
	if tick <= _last_tick:
		return
	_last_tick = tick
	_pos_hist[tick] = pos
	var drop_below := tick - _keep_ticks
	for k in _pos_hist.keys():
		if k < drop_below:
			_pos_hist.erase(k)
	_tick_list = _pos_hist.keys()
	_tick_list.sort()
	if _tick_list.size() >= 2:
		_clock = float(_tick_list[-1]) - 1.0


# 缓冲是否已够插值(至少两个快照)。不够时调用方应直落「最新权威位置」,别调 sample()。
func ready() -> bool:
	return _clock >= 0.0 and _tick_list.size() >= 2


# 把渲染时钟按真实时间往前推:delta 秒 → tick 域(× SNAPSHOT_HZ)。
func advance(delta: float) -> void:
	_clock += delta * SNAPSHOT_HZ


# 当前时钟落在哪两个相邻快照之间就线性插哪个;跨接缝取**最短向量**后取模回 canonical。
# 时钟越过已收到的最新(丢包/卡顿间隙)→ 冻结在最新;早于缓冲最前 → 冻结最早。
# 前置条件:ready() 为真。返回值是 canonical,调用方自行 anchor_to_nearest 到渲染锚点。
func sample() -> Vector2:
	var i := _tick_list.size() - 1
	while i > 0 and float(_tick_list[i]) > _clock:
		i -= 1
	var a: int = _tick_list[i]
	var pa: Vector2 = _pos_hist[a]
	if i + 1 >= _tick_list.size():
		return pa
	var b: int = _tick_list[i + 1]
	var pb: Vector2 = _pos_hist[b]
	var alpha := clampf((_clock - float(a)) / float(b - a), 0.0, 1.0)
	return MazeGenerator.toroidal_lerp(pa, pb, alpha, _map_w, _map_h)


# 缓冲区当前快照数(**调试与断言用**:窗口裁剪 / 乱序丢弃这类行为从外面看不出来)。
func tick_count() -> int:
	return _tick_list.size()

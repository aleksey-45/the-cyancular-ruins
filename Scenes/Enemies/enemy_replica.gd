extends Node2D
# PvP 中立鸟视觉副本:复用对应敌人场景的外观(AnimatedSprite2D/黑鸟 shader/动画名),
# 物理/AI 全关(服务器权威),由服务器快照驱动。
# 位置走「双快照 + tick 域 alpha 插值」+ 锚本地玩家最近副本渲染——与 player_replica 同纪律:
# 相邻快照在环面跨接缝取最短向量插值、取模回 canonical,最后锚到本地玩家(相机)副本,不落远副本。

const SNAPSHOT_HZ := 60.0
const KEEP_TICKS := 4   # 位置缓冲窗口(插值 + 顶小丢包;鸟不需要对手那么长的抗抖动窗)

var _bird_id := 0
var _e: Node = null
var _anim: AnimatedSprite2D = null
var _canonical := Vector2.ZERO   # 最新快照 canonical(缓冲未满直落用)
var _anchor := Vector2.ZERO      # 本地玩家(相机)位置,每次快照更新
var _have := false

# ── 位置插值缓冲(与 player_replica 同款算法,精简版) ──
var _pos_hist: Dictionary = {}   # tick -> canonical 位置
var _tick_list: Array = []
var _last_tick := 0
var _clock := -1.0               # 渲染时钟(tick 域);<0 = 缓冲未满

func setup(bird_id: int, scene_path: String, pos: Vector2, anchor: Vector2) -> void:
	_bird_id = bird_id
	_anchor = anchor
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return
	_e = scene.instantiate()
	_e.set_physics_process(false)   # 服务器权威:本地绝不模拟物理/AI
	add_child(_e)
	_anim = _e.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	# 视觉副本不进 enemies 组:避免客户端 AoE/子弹把副本当权威敌结算;保留碰撞体只是
	# 让本地视觉子弹"撞到鸟就消失"(与服务器子弹撞权威鸟一致)。
	if _e.is_in_group("enemies"):
		_e.remove_from_group("enemies")
	_canonical = pos
	global_position = MazeGenerator.anchor_to_nearest(pos, anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_have = true

func apply_remote(data: Dictionary, anchor: Vector2, tick: int) -> void:
	_anchor = anchor
	_canonical = data["pos"]
	# 即时态:朝向 + 动画名(服务器权威鸟正在播的动画),位置走缓冲
	if _anim != null:
		_anim.flip_h = bool(data.get("flip", false))
		var nm := str(data.get("anim", ""))
		if nm != "" and str(_anim.animation) != nm:
			_anim.play(nm)
	_push_position(tick, _canonical)

func _push_position(tick: int, pos: Vector2) -> void:
	if tick <= _last_tick:
		return
	_last_tick = tick
	_pos_hist[tick] = pos
	var drop_below := tick - KEEP_TICKS
	for k in _pos_hist.keys():
		if k < drop_below:
			_pos_hist.erase(k)
	_tick_list = _pos_hist.keys()
	_tick_list.sort()
	if _tick_list.size() >= 2:
		_clock = float(_tick_list[-1]) - 1.0

func _sample_position(clock: float) -> Vector2:
	var i := _tick_list.size() - 1
	while i > 0 and float(_tick_list[i]) > clock:
		i -= 1
	var a: int = _tick_list[i]
	var pa: Vector2 = _pos_hist[a]
	if i + 1 >= _tick_list.size():
		return pa
	var b: int = _tick_list[i + 1]
	var pb: Vector2 = _pos_hist[b]
	var alpha := clampf((clock - float(a)) / float(b - a), 0.0, 1.0)
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var d := MazeGenerator.toroidal_delta_px(pa, pb, w, h)
	return MazeGenerator.wrap_to_range(pa + d * alpha, w, h)

func _process(delta: float) -> void:
	if not _have or _e == null:
		return
	if _clock >= 0.0 and _tick_list.size() >= 2:
		_clock += delta * SNAPSHOT_HZ
		var canonical := _sample_position(_clock)
		global_position = MazeGenerator.anchor_to_nearest(canonical, _anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	else:
		# 开场缓冲未满:直落最新权威位置
		global_position = MazeGenerator.anchor_to_nearest(_canonical, _anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
